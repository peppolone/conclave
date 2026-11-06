import type { Provider } from "../config.ts";
import type { ChatRequest, ChatResult } from "./types.ts";

const TIMEOUT_MS = 120_000;
const MAX_RETRIES = 2;
const ATTEMPT_WITH_RESERVE_MS = 35_000;

export class HttpError extends Error {
  status: number;
  retryAfter: number;
  constructor(status: number, message: string, retryAfter: number) {
    super(message);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

/**
 * Caratteri tipografici che alcuni modelli (GPT-OSS) usano a centinaia: spazi stretti
 * e trattini non separabili rendono difficili ricerca e copia. Si portano a quelli normali.
 */
export function normalizeText(s: string): string {
  return s
    .replace(/[    ]/g, " ")
    .replace(/[‐‑]/g, "-")
    .replace(/​/g, "");
}

/** "Please try again in 22.5s" / "1m2.5s" / "750ms" → secondi (0 se assente). */
export function parseTryAgain(msg: string): number {
  const m = msg.match(/try again in\s+((?:\d+h)?(?:\d+m(?!s))?(?:[\d.]+s)?|[\d.]+ms)/i);
  if (!m || !m[1]) return 0;
  const t = m[1];
  if (/^[\d.]+ms$/.test(t)) return Number(t.slice(0, -2)) / 1000;
  const h = Number(t.match(/(\d+)h/)?.[1] ?? 0);
  const min = Number(t.match(/(\d+)m(?!s)/)?.[1] ?? 0);
  const s = Number(t.match(/([\d.]+)s/)?.[1] ?? 0);
  return h * 3600 + min * 60 + s;
}

/** Attesa interrompibile: se il dibattito viene annullato o scade il tempo, si smette subito. */
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason ?? new Error("annullato"));
    const t = setTimeout(() => { signal?.removeEventListener("abort", onAbort); resolve(); }, ms);
    const onAbort = () => { clearTimeout(t); reject(signal!.reason ?? new Error("annullato")); };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/** Errore 429 che non si risolve aspettando qualche secondo. */
export function isHardLimit(message: string): boolean {
  return /exceeded your current quota|limit: 0\b|per day|\(RPD\)|\(TPD\)|reduce your message size|request too large/i.test(message);
}

export async function once(p: Provider, model: string, req: ChatRequest, timeoutMs = TIMEOUT_MS): Promise<string> {
  const key = process.env[p.keyEnv]?.trim();
  if (!key) throw new Error(`chiave ${p.keyEnv} mancante nel file .env`);

  const signals = [AbortSignal.timeout(timeoutMs)];
  if (req.signal) signals.push(req.signal);

  const res = await fetch(`${p.baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${key}`,
      // Intestazioni facoltative richieste da OpenRouter per identificare l'app.
      "HTTP-Referer": "http://localhost",
      "X-Title": "AI Council",
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: req.system },
        { role: "user", content: req.user },
      ],
      // Margine ampio: nei modelli che "ragionano" anche il ragionamento consuma questo limite.
      max_tokens: req.maxTokens ?? 4096,
      temperature: 0.6,
      // Parametri specifici del provider (es. Gemini: ragionamento leggero), da models.json.
      ...(p.extraBody ?? {}),
    }),
    signal: AbortSignal.any(signals),
  });

  const raw = await res.text();
  if (!res.ok) {
    let msg = raw.slice(0, 300);
    try {
      // Google a volte restituisce l'errore dentro un array: [{ error: {...} }]
      const parsed = JSON.parse(raw);
      const j = Array.isArray(parsed) ? parsed[0] : parsed;
      msg = j?.error?.message ?? j?.message ?? msg;
    } catch { /* risposta non JSON */ }
    const ra = Number(res.headers.get("retry-after"));
    const hinted = parseTryAgain(msg);
    throw new HttpError(res.status, `HTTP ${res.status}: ${msg}`, Number.isFinite(ra) && ra > 0 ? ra : hinted);
  }

  let j: any;
  try { j = JSON.parse(raw); } catch { throw new Error("risposta non valida dal provider (non è JSON)"); }
  const msg = j.choices?.[0]?.message;
  let text: string = typeof msg?.content === "string" ? msg.content : "";
  // Alcuni modelli di ragionamento includono il "pensiero" tra tag <think>.
  text = normalizeText(text.replace(/<think>[\s\S]*?<\/think>/g, "")).trim();
  if (!text) throw new Error("risposta vuota dal modello");
  // Risposta tagliata dal limite di lunghezza: lo si dichiara, così giudice e utente lo sanno.
  if (j.choices?.[0]?.finish_reason === "length") text += "\n\n[…risposta troncata dal limite di lunghezza]";
  return text;
}

/**
 * Prova i modelli in ordine: il primo è il principale, gli altri sono di riserva.
 * Un modello ritirato (400/404) passa subito al successivo; uno occupato (429/5xx)
 * passa subito alla riserva, oppure viene ritentato se è l'ultimo modello.
 */
export async function chatOpenAI(p: Provider, models: string[], req: ChatRequest): Promise<ChatResult> {
  const started = Date.now();
  let lastError: unknown;
  for (const [i, model] of models.entries()) {
    const hasNext = i < models.length - 1;
    const maxRetries = hasNext ? 0 : MAX_RETRIES; // con una riserva disponibile non si aspetta
    for (let attempt = 0; ; attempt++) {
      try {
        // Se c'è una riserva, un modello lento non deve consumare tutto il tempo del round.
        const text = await once(p, model, req, hasNext ? ATTEMPT_WITH_RESERVE_MS : TIMEOUT_MS);
        return { text, ms: Date.now() - started, model };
      } catch (e) {
        lastError = e;
        if (req.signal?.aborted) throw e;
        // Modello che non risponde in tempo o risposta illeggibile: si passa alla riserva, se c'è.
        if (!(e instanceof HttpError)) {
          if (hasNext) break;
          throw e;
        }
        const busy = e.status === 429 || e.status >= 500;
        const gone = e.status === 404 || e.status === 400;
        // Quota giornaliera esaurita o richiesta troppo grande: riprovare tra pochi secondi è inutile.
        const quota = e.status === 429 && isHardLimit(e.message);
        if (busy && !quota && attempt < maxRetries) {
          // Limite al minuto o sovraccarico: si aspetta quanto indica il provider (max 45 s),
          // altrimenti 5 s, 10 s… L'attesa si interrompe se scade il tempo del round.
          const waitS = Math.min(e.retryAfter > 0 ? e.retryAfter + 0.5 : 5 * (attempt + 1), 45);
          await sleep(waitS * 1000, req.signal);
          continue;
        }
        if ((busy || gone) && hasNext) break; // passa alla riserva
        throw e;
      }
    }
  }
  throw lastError;
}
