// Provider finto compatibile OpenAI per i test di stress del motore.
// Uso: node tests/chaos/mock-provider.mjs [porta]   (oppure MOCK_PORT=<n>; 0 = porta libera)
// Stampa "MOCK_PORT=<n>" su stdout quando è pronto.
//
// Il comportamento dipende dal nome del modello (vedi BEHAVIORS). Le prove del controllo
// d'avvio del motore (user "Scrivi solo: OK") ricevono sempre "OK": così la sostituzione
// automatica non cambia i modelli prima degli scenari. Sono contate a parte in /stats.

import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

export const MODELS = [
  "ok-a", "ok-b", "hang", "slow", "ratelimit", "quota", "crash500",
  "empty", "huge", "html", "flaky-critique", "length", "gone", "otpm", "leaky", "titleonly", "tpm",
];

/** Modelli di Groq che supportano browser_search: elencati in /models, non membri del consiglio di prova. */
export const SEARCH_MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];

/** Testo del dossier finto: con un rimando interno di GPT-OSS da ripulire e una fonte. */
export const DOSSIER_MARK = "DOSSIER-CHAOS-7731";
export const DOSSIER_URL = "https://example.org/fonte-chaos";

/** Chiave Google finta (formato reale) che "leaky" ripete nei suoi errori. */
export const FAKE_GOOGLE_KEY = "AIzaSyChaos0123456789abcdefghijklmnopq";

const calls = Object.create(null);   // chiamate di chat per modello (prove escluse)
const probes = Object.create(null);  // prove del controllo d'avvio per modello
const auths = Object.create(null);   // intestazione Authorization ricevuta per modello ("whoami")
const seenPhase = new Set();         // "ratelimit": prima chiamata per fase già vista
let hanging = 0;                     // connessioni "hang" ancora aperte
/** Prompt ricevuti per scenario (solo scenari "web…" e "att…"): /prompts/<scenario>. */
const prompts = Object.create(null);

/** Fase del dibattito ricavata dal prompt. */
function phaseOf(system, user) {
  if (/giudice/i.test(system)) return "verdict";
  if (user.includes("Round 1")) return "critique";
  if (user.includes("Round 2")) return "revise";
  if (user.includes("Round 3")) return "final";
  return "initial";
}

/**
 * Etichetta dello scenario inserita nella domanda: "[scenario:x]". Vale l'ultima: negli
 * approfondimenti la domanda della discussione madre (con la sua etichetta) viene prima.
 */
function scenarioOf(user) {
  return [...user.matchAll(/\[scenario:([\w-]+)\]/g)].at(-1)?.[1] ?? "?";
}

function okText(model, user) {
  let t = `**Risposta di prova** del modello ${model}.

| Voce | Valore |
|---|---|
| Uno<br>due | 10 000 persone |
| Tre<br>quattro | effetto non‑lineare |

- primo punto con *corsivo* e \`codice\`
- secondo punto: 3 % in più, anno‑2026`;
  if (user.includes("Round 2")) t += "\n\nCAMBIAMENTI: minori";
  if (user.includes("Round 3")) t += "\n\nFIDUCIA: media";
  return t;
}

const HTML_TEXT = `Testo ostile:
<script>alert(1)</script>
<img src=x onerror=alert(1)>
[x](javascript:alert(1))
<iframe src="javascript:alert(1)"></iframe>
<a href="javascript:alert(1)" onclick="alert(1)">clic</a>
<svg onload=alert(1)>
Fine.`;

function send(res, status, body, headers = {}) {
  res.writeHead(status, { "Content-Type": "application/json", ...headers });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

function completion(model, content, finish = "stop") {
  return {
    id: "chatcmpl-chaos", object: "chat.completion", created: Math.floor(Date.now() / 1000), model,
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: finish }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  };
}

const err = (message, type = "error") => ({ error: { message, type } });

async function readJson(req) {
  let s = "";
  for await (const c of req) s += c;
  try { return JSON.parse(s || "{}"); } catch { return {}; }
}

async function handle(req, res) {
  const path = new URL(req.url ?? "/", "http://x").pathname.replace(/\/+$/, "");

  if (req.method === "GET" && path.endsWith("/models")) {
    return send(res, 200, { object: "list", data: [...MODELS, ...SEARCH_MODELS, "paced", "whoami"].map((id) => ({ id, object: "model", owned_by: "chaos" })) });
  }
  const pm = path.match(/\/prompts\/([\w-]+)$/);
  if (req.method === "GET" && pm) return send(res, 200, prompts[pm[1]] ?? []);
  if (req.method === "GET" && path.endsWith("/stats")) {
    return send(res, 200, { calls, probes, hanging, auths });
  }
  if (req.method !== "POST" || !path.endsWith("/chat/completions")) return send(res, 404, err("not found"));

  const body = await readJson(req);
  const model = String(body.model ?? "");
  const msgs = Array.isArray(body.messages) ? body.messages : [];
  const system = String(msgs.find((m) => m.role === "system")?.content ?? "");
  const user = String(msgs.find((m) => m.role === "user")?.content ?? "");
  // "whoami": ricorda la chiave ricevuta (solo prove: verifica che arrivi quella data dall'app).
  if (model === "whoami") auths.whoami = String(req.headers.authorization ?? "");

  if (user.trim() === "Scrivi solo: OK") {
    probes[model] = (probes[model] ?? 0) + 1;
    return send(res, 200, completion(model, "OK"));
  }
  calls[model] = (calls[model] ?? 0) + 1;
  const searching = Array.isArray(body.tools) && body.tools.some((t) => t?.type === "browser_search");
  const scenario = scenarioOf(user);
  if (/^(web|att)/.test(scenario)) {
    (prompts[scenario] ??= []).push({
      model, phase: searching ? "research" : phaseOf(system, user), system, user,
      tools: body.tools ?? null, reasoning_effort: body.reasoning_effort ?? null, max_tokens: body.max_tokens ?? null,
    });
  }

  switch (model) {
    case "ok-a":
    case "ok-b":
    case "whoami":
      return send(res, 200, completion(model, okText(model, user)));
    case "hang":
      hanging++;
      req.socket.setTimeout(0);
      res.on("close", () => hanging--);
      return; // non risponde mai
    case "paced": {
      // Per provare l'interfaccia dal vivo: 3–7 s di attesa e una risposta lunga.
      const t = setTimeout(() => send(res, 200, completion(model, Array(6).fill(okText(model, user)).join("\n\n"))),
        3000 + Math.random() * 4000);
      res.on("close", () => clearTimeout(t));
      return;
    }
    case "slow": {
      const t = setTimeout(() => send(res, 200, completion(model, okText(model, user))), 20_000);
      res.on("close", () => clearTimeout(t));
      return;
    }
    case "ratelimit": {
      const key = `${scenarioOf(user)}|${phaseOf(system, user)}`;
      if (!seenPhase.has(key)) {
        seenPhase.add(key);
        return send(res, 429, err(
          "Rate limit reached for model `ratelimit` in organization org-chaos on tokens per minute (TPM): Limit 6000, Used 5800, Requested 900. Please try again in 2.5s.",
          "tokens",
        ));
      }
      return send(res, 200, completion(model, okText(model, user)));
    }
    case "quota":
      return send(res, 429, err("You exceeded your current quota, please check your plan and billing details.", "insufficient_quota"));
    case "crash500":
      return send(res, 500, err("Internal server error", "server_error"));
    case "empty":
      return send(res, 200, completion(model, ""));
    case "huge":
      return send(res, 200, completion(model, "Lorem ipsum dolor sit amet. ".repeat(10_715).slice(0, 300_000).padEnd(300_000, "x")));
    case "html":
      return send(res, 200, completion(model, HTML_TEXT));
    case "flaky-critique":
      if (user.includes("Round 1")) return send(res, 500, err("Internal server error (flaky)", "server_error"));
      return send(res, 200, completion(model, okText(model, user)));
    case "length":
      return send(res, 200, completion(model, okText(model, user), "length"));
    case "otpm": {
      // Come Qwen su Groq gratis: rifiuta max_tokens oltre 1000.
      const mt = Number(body.max_tokens ?? 0);
      if (!mt || mt > 1000) return send(res, 429, err(`Request too large for model \`otpm\` in organization org-chaos service tier \`on_demand\` on output tokens per minute (OTPM): Limit 1000, Requested ${mt || 4096}. The request's expected output tokens exceed the enforced limit; reduce max_tokens (or the request's expected output) and try again.`, "tokens"));
      return send(res, 200, completion(model, okText(model, user)));
    }
    case "leaky": {
      // Come OpenAI con una chiave sbagliata: il provider ripete la chiave ricevuta nel messaggio.
      const key = String(req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
      return send(res, 401, err(`Incorrect API key provided: ${key}. Also tried ${FAKE_GOOGLE_KEY} (Authorization: Bearer ${key}).`, "invalid_request_error"));
    }
    case "titleonly":
      // Da giudice scrive solo la riga del titolo: il verdetto resta vuoto.
      if (phaseOf(system, user) === "verdict") return send(res, 200, completion(model, "TITOLO: Solo il titolo"));
      return send(res, 200, completion(model, okText(model, user)));
    case "openai/gpt-oss-120b":
    case "openai/gpt-oss-20b":
      // Come GPT-OSS su Groq: con browser_search produce il dossier (con i rimandi 【…】).
      if (!searching) return send(res, 200, completion(model, okText(model, user)));
      if (/hang/.test(scenario)) {
        hanging++;
        req.socket.setTimeout(0);
        res.on("close", () => hanging--);
        return; // la ricerca non finisce mai
      }
      {
        const c = completion(model, `## Punti chiave\n- ${DOSSIER_MARK}: il treno impiega 3 ore 【2†L6-L10】.\n## Fonti\n- Fonte di prova: ${DOSSIER_URL}`);
        // Pagine consultate dallo strumento: quella non citata nel testo va aggiunta dal motore.
        c.choices[0].message.executed_tools = [{ type: "browser_search", search_results: { results: [
          { title: "x", url: DOSSIER_URL }, { title: "y", url: "https://example.org/altra" }] } }];
        return send(res, 200, c);
      }
    case "tpm": {
      // Come Groq gratis (~8.000 token al minuto): un prompt enorme viene rifiutato con 413.
      const chars = system.length + user.length;
      if (chars > 20_000) return send(res, 413, err(`Request too large for model \`tpm\` in organization org-chaos service tier \`on_demand\` on tokens per minute (TPM): Limit 8000, Requested ${Math.round(chars / 4)}, please reduce your message size and try again.`, "tokens"));
      return send(res, 200, completion(model, okText(model, user)));
    }
    case "gone":
      return send(res, 404, err(`The model \`${model}\` does not exist or you do not have access to it. model not found`, "invalid_request_error"));
    default:
      return send(res, 404, err(`model not found: ${model}`, "invalid_request_error"));
  }
}

// Server solo se eseguito direttamente: run.mjs importa questo file per MODELS e FAKE_GOOGLE_KEY.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.argv[2] ?? process.env.MOCK_PORT ?? 0);
  const server = createServer((req, res) => {
    handle(req, res).catch((e) => { if (!res.headersSent) send(res, 500, err(String(e))); else res.end(); });
  });
  server.listen(port, "127.0.0.1", () => {
    console.log(`MOCK_PORT=${server.address().port}`);
  });
  for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { server.closeAllConnections?.(); process.exit(0); });
}
