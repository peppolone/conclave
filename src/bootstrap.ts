/**
 * Primo modulo caricato dal motore (importato da config.ts), prima di qualunque file scritto.
 *
 * - File e cartelle nuovi leggibili solo dall'utente (database, log, selection.json…).
 * - Avviato dall'app Mac: la prima riga dello stdin è un JSON `{"token": "…", "keys": {…}}`.
 *   Il token protegge l'API locale (`Authorization: Bearer …`) e non passa dall'ambiente, che
 *   altri processi possono leggere e che i processi figli (Claude CLI) ereditano.
 *   `keys` (facoltativo) sono le chiavi API lette dall'app dal Portachiavi: finiscono in
 *   `process.env` prima che config.ts carichi `.env`, che non sovrascrive variabili già
 *   presenti, quindi hanno la precedenza sul file.
 */

process.umask(0o077);

/** Token richiesto dall'API; vuoto = nessun controllo (solo `npm start` in sviluppo). */
export let engineToken = "";

/** Nomi delle chiavi ricevute dall'app (mai i valori): la Claude CLI non le eredita. */
export const appKeyNames: string[] = [];

/** Nome di variabile accettato per una chiave: maiuscole, cifre e `_`, finale `_KEY` o `_TOKEN`. */
const KEY_NAME = /^[A-Z][A-Z0-9_]{0,63}$/;
const KEY_SUFFIX = /_(KEY|TOKEN)$/;
/** Solo ASCII stampabile senza spazi: una chiave vera non ha altro, e un a capo romperebbe l'intestazione HTTP. */
const KEY_VALUE = /^[\x21-\x7e]+$/;
const MAX_KEYS = 64;
const MAX_VALUE = 4096;
/** Sotto questa lunghezza redact.ts non maschera il valore: meglio scartarlo che rischiare di mostrarlo. */
const MIN_VALUE = 8;

/**
 * Imposta in `process.env` le chiavi valide di `keys`; scarta il resto senza fermare l'avvio.
 * Nel log finiscono solo conteggi e nomi validi, mai i valori.
 */
function applyKeys(keys: unknown): void {
  if (keys === undefined) return;
  if (keys === null || typeof keys !== "object" || Array.isArray(keys)) {
    console.error("Chiavi dall'app ignorate: \"keys\" non è un oggetto.");
    return;
  }
  let skipped = 0;
  // Object.keys: solo proprietà proprie (JSON.parse crea "__proto__" come proprietà normale,
  // che comunque non supera KEY_NAME).
  for (const name of Object.keys(keys)) {
    const value = (keys as Record<string, unknown>)[name];
    const v = typeof value === "string" ? value.trim() : "";
    const ok = KEY_NAME.test(name) && KEY_SUFFIX.test(name) && !name.startsWith("COUNCIL_")
      && v.length >= MIN_VALUE && v.length <= MAX_VALUE && KEY_VALUE.test(v)
      && appKeyNames.length < MAX_KEYS;
    if (!ok) { skipped++; continue; }
    process.env[name] = v;
    if (!appKeyNames.includes(name)) appKeyNames.push(name);
  }
  if (skipped) console.error(`Chiavi dall'app ignorate perché non valide: ${skipped}.`);
}

function firstLine(): Promise<string | null> {
  return new Promise((resolve) => {
    let buf = "";
    const onData = (chunk: Buffer) => {
      buf += chunk.toString("utf8");
      const i = buf.indexOf("\n");
      if (i < 0) return;
      process.stdin.off("data", onData);
      process.stdin.off("end", onEnd);
      process.stdin.pause();
      resolve(buf.slice(0, i));
    };
    const onEnd = () => resolve(null);
    process.stdin.on("data", onData);
    process.stdin.once("end", onEnd);
  });
}

if (process.env.COUNCIL_PARENT === "app") {
  const line = await firstLine();
  // L'app si è chiusa prima di mandare il token: niente da servire.
  if (line === null) process.exit(0);
  let hello: { token?: unknown; keys?: unknown } = {};
  try {
    const parsed: unknown = JSON.parse(line);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) hello = parsed;
  } catch { /* sotto */ }
  const token = hello.token;
  if (typeof token !== "string" || token.length < 32) {
    console.error("Avvio rifiutato: token del motore mancante o non valido sullo stdin.");
    process.exit(1);
  }
  engineToken = token;
  applyKeys(hello.keys);
}
