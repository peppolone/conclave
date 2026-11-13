// Ricerca sul web prima del dibattito: un solo ricercatore prepara un dossier di fatti
// recenti con le fonti, che entra nel prompt iniziale e in quello del giudice.
// Chi cerca: Claude (strumenti WebSearch/WebFetch, inclusi nell'abbonamento) se c'è una voce
// Claude; altrimenti GPT-OSS su Groq con browser_search (gratuito). Gemini gratuito non ha
// la ricerca, OpenRouter la fa pagare, Mistral non la offre in chat/completions.
import { config, isAvailable, type ModelDef } from "../config.ts";
import { chatClaude } from "../adapters/claude-cli.ts";
import { chatOpenAI } from "../adapters/openai-compat.ts";
import type { ChatResult } from "../adapters/types.ts";
import { modelsToTry, getHealth } from "../health.ts";
import { familyOf } from "../family.ts";
import * as P from "./prompts.ts";

/** Su Groq browser_search funziona solo con questi due modelli. */
const GROQ_SEARCH_MODEL = /(^|\/)gpt-oss-(120b|20b)$/;
const GROQ_SEARCH_DEFAULT = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];
/** Un tentativo con la ricerca dura più di una risposta normale. */
const GROQ_ATTEMPT_MS = 120_000;

export interface Researcher {
  def: ModelDef;
  /** Etichetta leggibile per l'interfaccia ("Claude", "GPT-OSS (Groq)"). */
  via: string;
}

function isGroq(m: ModelDef): boolean {
  const p = m.provider ? config.providers[m.provider] : undefined;
  return m.provider === "groq" || /(^|\.)groq\.com(\/|$)/.test(p?.baseUrl.replace(/^https?:\/\//, "") ?? "");
}

/** Chi può fare la ricerca adesso, o null se nessuno. */
export function findResearcher(): Researcher | null {
  const claude = config.models.find((m) => m.kind === "claude-cli" && isAvailable(m));
  if (claude) return { def: claude, via: "Claude" };
  const groq = config.models.find((m) =>
    m.kind === "openai" && isGroq(m) && (m.family ?? familyOf(m.model).id) === "gpt-oss" &&
    isAvailable(m) && getHealth(m.id).status !== "down");
  if (groq) return { def: groq, via: "GPT-OSS (Groq)" };
  return null;
}

/** Esegue la ricerca. Il segnale ferma tutto (annullamento del dibattito o tempo scaduto). */
export async function runResearch(r: Researcher, question: string, claudeModel: string, signal: AbortSignal): Promise<ChatResult> {
  const today = new Date().toISOString().slice(0, 10);
  const req = { system: P.SYSTEM_RESEARCHER, user: P.researchPrompt(question, today), signal, webSearch: true };
  if (r.def.kind === "claude-cli") {
    const res = await chatClaude(claudeModel, req);
    return { ...res, model: res.model ?? claudeModel };
  }
  const p = config.providers[r.def.provider!];
  if (!p) throw new Error(`provider "${r.def.provider}" non definito in models.json`);
  // Solo le varianti che supportano lo strumento (non, ad esempio, gpt-oss-safeguard).
  const chain = (await modelsToTry(r.def)).filter((x) => GROQ_SEARCH_MODEL.test(x));
  return chatOpenAI(p, chain.length ? chain : GROQ_SEARCH_DEFAULT, { ...req, timeoutMs: GROQ_ATTEMPT_MS });
}
