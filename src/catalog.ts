// Catalogo dei modelli offerti da ogni provider, con stima di qualità e indicazione "gratis".
import { config, type Provider } from "./config.ts";
import { once, HttpError, isHardLimit } from "./adapters/openai-compat.ts";
import { familyOf } from "./family.ts";
import { redact } from "./redact.ts";

export interface CatalogModel {
  id: string;
  name: string;
  created?: number;        // secondi Unix, se il provider lo fornisce
  context?: number;
  free: boolean | null;    // null = dipende dal piano/quota: si scopre con "Prova"
  freeNote?: string;
  description?: string;
  score: number;           // stima euristica: più alto = più capace/recente
  recommended: boolean;
  family: string;          // es. "gemini", "gpt-oss": una voce del consiglio per famiglia
  familyLabel: string;
}

/** Provider con piano gratuito su tutti i modelli (con limiti di frequenza). */
const FREE_PLAN = new Set(["groq", "mistral", "cerebras"]);

// Modelli che non servono a una discussione testuale.
const NOT_CHAT = /(embed|tts|whisper|transcri|audio|speech|imagen|image|veo|lyria|guard|moderation|aqa|live|realtime|robotics|computer-use|search|ocr|rerank|dall-e|sora|native-audio|nano-banana|compound|playai|safeguard|orpheus|prompt-guard)/i;

const cache = new Map<string, { at: number; models: CatalogModel[] }>();
const TTL = 10 * 60_000;

function keyOf(p: Provider): string {
  const k = process.env[p.keyEnv]?.trim();
  if (!k) throw new Error(`manca la chiave ${p.keyEnv}`);
  return k;
}

async function getJson(url: string, headers: Record<string, string>): Promise<any> {
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`il provider ha risposto ${res.status}`);
  return res.json();
}

async function fetchRaw(id: string, p: Provider): Promise<Omit<CatalogModel, "score" | "recommended">[]> {
  if (id === "gemini") {
    // L'API nativa di Google dà nomi e limiti di contesto; quella compatibile OpenAI solo gli id.
    const j = await getJson("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000", { "x-goog-api-key": keyOf(p) });
    return (j.models ?? [])
      .filter((m: any) => (m.supportedGenerationMethods ?? []).includes("generateContent"))
      .map((m: any) => {
        const mid = String(m.name).replace(/^models\//, "");
        // Nel piano gratuito Google dà quota 0 ai modelli Pro, ad "Argon" e alla famiglia Omni.
        const paid = /(pro|argon|omni)/i.test(mid);
        // Quote giornaliere indicative del piano gratuito (pagina dei limiti di AI Studio, nov 2026).
        const note = paid ? "Non incluso nel piano gratuito"
          : /gemma/i.test(mid) ? "Gratis · quota alta (circa 14.000 richieste al giorno)"
          : /lite/i.test(mid) ? "Gratis · circa 500 richieste al giorno"
          : "Gratis · solo circa 20 richieste al giorno";
        return {
          id: mid, name: m.displayName ?? mid, context: m.inputTokenLimit, description: m.description,
          free: !paid, freeNote: note,
        };
      });
  }
  if (id === "openrouter") {
    const j = await getJson(`${p.baseUrl}/models`, {});
    return (j.data ?? []).map((m: any) => {
      const free = Number(m.pricing?.prompt) === 0 && Number(m.pricing?.completion) === 0;
      return {
        id: m.id, name: m.name ?? m.id, created: m.created, context: m.context_length, description: m.description,
        free, freeNote: free ? "Gratis (limite di richieste giornaliero)" : "A pagamento",
      };
    });
  }
  // Provider compatibili OpenAI (Groq, Mistral, Cerebras, OpenAI…)
  const j = await getJson(`${p.baseUrl}/models`, { Authorization: `Bearer ${keyOf(p)}` });
  return (j.data ?? [])
    .filter((m: any) => m.active !== false && !m.deprecation && m.capabilities?.completion_chat !== false)
    .map((m: any) => ({
      id: m.id, name: m.name && m.name !== m.id ? m.name : m.id, created: m.created,
      context: m.context_window ?? m.max_context_length, description: m.description,
      free: FREE_PLAN.has(id) ? true : id === "openai" ? false : null,
      freeNote: FREE_PLAN.has(id) ? "Gratis con il piano free (limiti al minuto)" : id === "openai" ? "A pagamento (crediti OpenAI)" : undefined,
    }));
}

/**
 * Stima euristica della capacità: recenza + dimensione + fascia del modello.
 * Nessun provider pubblica una "classifica": è un ordinamento indicativo.
 */
function score(m: Omit<CatalogModel, "score" | "recommended">, recency: number): number {
  const id = m.id.toLowerCase();
  let s = recency * 40;
  const size = id.match(/(\d+)b\b/);
  if (size) s += Math.min(25, Math.log2(Number(size[1])) * 3.5);
  if (/(^|[-/_.])(pro|large|max|opus|ultra|maverick|thinking|reasoner|r1)\b/.test(id)) s += 22;
  else if (/(flash|medium|sonnet|scout|instruct|chat|turbo)/.test(id)) s += 12;
  // Confini di parola: "gemini" contiene "mini" ma non è un modello piccolo.
  if (/(^|[-/_.:])(lite|mini|small|nano|tiny|instant|haiku|[1-9]b)([-/_.:]|$)/.test(id)) s -= 8;
  if (/(^|\/)gemma/.test(id)) s -= 12; // modelli open più piccoli dei Gemini dello stesso provider
  if (/(preview|exp|beta|alpha)/.test(id)) s -= 6;
  if (/latest/.test(id)) s += 2;
  if (m.free === false) s -= 30;
  return Math.round(s * 10) / 10;
}

/**
 * Numero di versione subito dopo il nome della famiglia (gemini-3.8-flash → 3.8),
 * usato se il provider non dà la data. Le date nel nome (…-09-2026) non contano.
 * -1 indica un alias "latest", che vale quanto la versione più recente.
 */
function versionOf(id: string): number {
  if (/latest/.test(id)) return -1;
  const v = id.match(/^(?:[a-z]+\/)?[a-z]+-(\d+(?:\.\d+)?)(?:[-_.]|$)/);
  return v ? Number(v[1]) : 0;
}

export async function listCatalog(providerId: string, fresh = false): Promise<CatalogModel[]> {
  const p = config.providers[providerId];
  if (!p) throw new Error(`provider "${providerId}" sconosciuto`);
  const hit = cache.get(providerId);
  if (!fresh && hit && Date.now() - hit.at < TTL) return hit.models;

  const raw = (await fetchRaw(providerId, p)).filter((m) => !NOT_CHAT.test(m.id));
  // Recenza normalizzata 0..1 all'interno del provider.
  const maxVersion = Math.max(0, ...raw.map((m) => versionOf(m.id)));
  const key = (m: (typeof raw)[number]) => m.created ?? (versionOf(m.id) === -1 ? maxVersion : versionOf(m.id));
  const sorted = [...new Set(raw.map(key))].sort((a, b) => a - b);
  const rec = (m: (typeof raw)[number]) => (sorted.length > 1 ? sorted.indexOf(key(m)) / (sorted.length - 1) : 1);

  const models: CatalogModel[] = raw
    .map((m) => {
      const f = familyOf(m.id);
      return { ...m, score: score(m, rec(m)), recommended: false, family: f.id, familyLabel: f.label };
    })
    .sort((a, b) => b.score - a.score);
  models.filter((m) => m.free !== false).slice(0, 3).forEach((m) => (m.recommended = true));
  cache.set(providerId, { at: Date.now(), models });
  return models;
}

export type ProbeStatus = "ok" | "busy" | "quota" | "gone" | "auth" | "error";
export interface ProbeResult { status: ProbeStatus; ms: number; message?: string }

/** Prova un modello con una richiesta minima. */
export async function probe(providerId: string, model: string): Promise<ProbeResult> {
  const p = config.providers[providerId];
  const started = Date.now();
  if (!p) return { status: "error", ms: 0, message: "provider sconosciuto" };
  try {
    await once(p, model, { system: "Rispondi in modo brevissimo.", user: "Scrivi solo: OK", maxTokens: 200, signal: AbortSignal.timeout(45_000) });
    return { status: "ok", ms: Date.now() - started };
  } catch (e) {
    const ms = Date.now() - started;
    const message = redact((e as Error).message).slice(0, 200);
    if (!(e instanceof HttpError)) return { status: "error", ms, message };
    if (e.status === 401 || e.status === 403) return { status: "auth", ms, message };
    if (e.status === 429) return { status: isHardLimit(message) ? "quota" : "busy", ms, message };
    if (e.status >= 500) return { status: "busy", ms, message };
    return { status: "gone", ms, message };
  }
}

/**
 * Modelli di una famiglia presso un provider, dal migliore al peggiore (solo quelli usabili
 * gratis o con stato sconosciuto). Il preferito, se indicato, va in testa.
 */
/** Famiglie "sorelle" usate come ultima riserva (es. Gemma per Gemini: quota giornaliera molto più alta). */
const RELATED: Record<string, string[]> = { gemini: ["gemma"] };

export async function familyChain(providerId: string, family: string, preferred?: string): Promise<string[]> {
  const cat = await listCatalog(providerId);
  const pick = (f: string) => cat.filter((c) => c.family === f && c.free !== false).map((c) => c.id);
  const all = [...pick(family), ...(RELATED[family] ?? []).flatMap(pick)];
  return preferred && preferred !== "auto" ? [preferred, ...all.filter((id) => id !== preferred)] : all;
}
