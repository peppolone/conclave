import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ChatRequest, ChatResult } from "./types.ts";
import { redact } from "../redact.ts";

// Cartella vuota come cwd: Claude non vede file di progetto.
const SANDBOX_DIR = mkdtempSync(join(tmpdir(), "conclave-"));
const TIMEOUT_MS = 240_000;

/**
 * Chiama Claude Code in modalità non interattiva usando l'abbonamento Pro.
 * Nessun tool, nessun MCP, nessuna impostazione utente: solo testo.
 */
export function chatClaude(model: string, req: ChatRequest): Promise<ChatResult> {
  const started = Date.now();
  const env = { ...process.env };
  // Se fosse impostata una API key, Claude Code la userebbe al posto dell'abbonamento.
  delete env.ANTHROPIC_API_KEY;

  const args = [
    "-p",
    "--output-format", "json",
    "--tools", "",
    "--no-session-persistence",
    "--strict-mcp-config",
    "--setting-sources", "",
    "--system-prompt", req.system,
    "--model", model,
  ];

  return new Promise((resolve, reject) => {
    const child = spawn("claude", args, { cwd: SANDBOX_DIR, env, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), TIMEOUT_MS);
    const onAbort = () => child.kill("SIGTERM");
    req.signal?.addEventListener("abort", onAbort, { once: true });

    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(new Error(`claude non avviabile: ${e.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      req.signal?.removeEventListener("abort", onAbort);
      try {
        const j = JSON.parse(out) as { result?: string; is_error?: boolean };
        if (j.is_error || typeof j.result !== "string") {
          reject(new Error(`Claude: ${String(j.result ?? "errore sconosciuto").slice(0, 300)}`));
          return;
        }
        resolve({ text: j.result.trim(), ms: Date.now() - started });
      } catch {
        reject(new Error(`Claude (exit ${code}): ${redact((err || out).slice(0, 300)) || "nessun output"}`));
      }
    });
    // Se claude esce prima di leggere tutto il prompt (annullamento, timeout, errore d'avvio)
    // la scrittura dà EPIPE: l'esito si gestisce già in "close", qui va solo evitato il crash.
    child.stdin.on("error", () => {});
    child.stdin.end(req.user);
  });
}
