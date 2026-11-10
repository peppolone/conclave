/**
 * Primo modulo caricato dal motore (importato da config.ts), prima di qualunque file scritto.
 *
 * - File e cartelle nuovi leggibili solo dall'utente (database, log, selection.json…).
 * - Avviato dall'app Mac: la prima riga dello stdin è un JSON `{"token": "…"}`. Il token
 *   protegge l'API locale (`Authorization: Bearer …`) e non passa dall'ambiente, che altri
 *   processi possono leggere e che i processi figli (Claude CLI) ereditano.
 */

process.umask(0o077);

/** Token richiesto dall'API; vuoto = nessun controllo (solo `npm start` in sviluppo). */
export let engineToken = "";

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
  let token: unknown;
  try { token = (JSON.parse(line) as { token?: unknown }).token; } catch { /* sotto */ }
  if (typeof token !== "string" || token.length < 32) {
    console.error("Avvio rifiutato: token del motore mancante o non valido sullo stdin.");
    process.exit(1);
  }
  engineToken = token;
}
