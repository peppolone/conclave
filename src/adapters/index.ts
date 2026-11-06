import { config, type ModelDef } from "../config.ts";
import { modelsToTry } from "../health.ts";
import { chatClaude } from "./claude-cli.ts";
import { chatOpenAI } from "./openai-compat.ts";
import type { ChatRequest, ChatResult } from "./types.ts";

export type { ChatRequest, ChatResult } from "./types.ts";

export function chat(m: ModelDef, req: ChatRequest): Promise<ChatResult> {
  if (m.kind === "claude-cli") return chatClaude(m.model, req);
  const p = m.provider ? config.providers[m.provider] : undefined;
  if (!p) return Promise.reject(new Error(`provider "${m.provider}" non definito in models.json`));
  // Prima il modello risultato funzionante al controllo d'avvio, poi configurato e riserve.
  return chatOpenAI(p, modelsToTry(m), req);
}
