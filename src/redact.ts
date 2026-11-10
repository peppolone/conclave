/**
 * Nasconde le chiavi API nei testi che escono dal motore (log, errori salvati e mostrati).
 * I provider a volte ripetono la chiave nei messaggi d'errore ("Incorrect API key provided: sk-…").
 */

import { engineToken } from "./bootstrap.ts";

const MASK = "[chiave nascosta]";

/** Formati noti: Google (AIza…), Groq (gsk_…), OpenAI/OpenRouter/Anthropic (sk-…), Cerebras (csk-…). */
const PATTERNS = [
  /AIza[0-9A-Za-z_-]{30,}/g,
  /gsk_[0-9A-Za-z]{20,}/g,
  /\b(?:sk|csk)-[0-9A-Za-z_-]{20,}/g,
  /(Bearer\s+)[0-9A-Za-z._~+/=-]{16,}/gi,
];

/** Valori segreti presenti nell'ambiente (chiavi dei provider e token del motore). */
function secrets(): string[] {
  const out = engineToken ? [engineToken] : [];
  for (const [k, v] of Object.entries(process.env)) {
    if (!v || v.trim().length < 8) continue;
    if (/_(API_)?KEY$|_TOKEN$/.test(k)) out.push(v.trim());
  }
  // Prima i più lunghi: un valore che ne contiene un altro va sostituito per intero.
  return out.sort((a, b) => b.length - a.length);
}

export function redact(text: string): string {
  let s = text;
  for (const v of secrets()) s = s.split(v).join(MASK);
  for (const re of PATTERNS) s = s.replace(re, (_m, bearer) => (typeof bearer === "string" ? bearer + MASK : MASK));
  return s;
}

/** Filtra tutto ciò che il motore scrive su stdout/stderr (l'app lo salva in server.log). */
export function redactProcessOutput() {
  for (const stream of [process.stdout, process.stderr]) {
    const write = stream.write.bind(stream) as (...a: unknown[]) => boolean;
    stream.write = ((chunk: unknown, ...rest: unknown[]) =>
      write(typeof chunk === "string" ? redact(chunk) : chunk instanceof Uint8Array ? redact(Buffer.from(chunk).toString("utf8")) : chunk, ...rest)) as typeof stream.write;
  }
}
