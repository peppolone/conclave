import type { Provider } from "../config.ts";
import type { ChatRequest, ChatResult } from "./types.ts";

const TIMEOUT_MS = 120_000;
const MAX_RETRIES = 2;

export class HttpError extends Error {
  status: number;
  retryAfter: number;
  constructor(status: number, message: string, retryAfter: number) {
    super(message);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

export async function once(p: Provider, model: string, req: ChatRequest): Promise<string> {
  const key = process.env[p.keyEnv]?.trim();
  if (!key) throw new Error(`chiave ${p.keyEnv} mancante nel file .env`);

  const signals = [AbortSignal.timeout(TIMEOUT_MS)];
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
    throw new HttpError(res.status, `HTTP ${res.status}: ${msg}`, Number.isFinite(ra) ? ra : 0);
  }

  const j = JSON.parse(raw);
  const msg = j.choices?.[0]?.message;
  let text: string = typeof msg?.content === "string" ? msg.content : "";
  // Alcuni modelli di ragionamento includono il "pensiero" tra tag <think>.
  text = text.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
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
        const text = await once(p, model, req);
        return { text, ms: Date.now() - started, model };
      } catch (e) {
        lastError = e;
        if (req.signal?.aborted || !(e instanceof HttpError)) throw e;
        const busy = e.status === 429 || e.status >= 500;
        const gone = e.status === 404 || e.status === 400;
        // Quota giornaliera esaurita (o modello escluso dal piano): riprovare tra pochi secondi è inutile.
        const quota = e.status === 429 && /quota|limit: 0|per ?day|billing/i.test(e.message);
        if (busy && !quota && attempt < maxRetries) {
          // Limite di frequenza o sovraccarico: attesa breve e nuovo tentativo.
          const waitS = Math.min(Math.max(e.retryAfter, 5 * (attempt + 1)), 30);
          await new Promise((r) => setTimeout(r, waitS * 1000));
          continue;
        }
        if ((busy || gone) && hasNext) break; // passa alla riserva
        throw e;
      }
    }
  }
  throw lastError;
}
