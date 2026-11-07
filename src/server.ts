import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { config, isAvailable, findModel, PORT, selection, validateSelection, saveSelection } from "./config.ts";
import { createDebate, listDebates, getDebate, deleteDebate } from "./db.ts";
import { runDebate, type DebateEvent, type Rounds } from "./debate/orchestrator.ts";
import { listCatalog, probe } from "./catalog.ts";
import { getHealth, runHealthCheck, isChecking } from "./health.ts";

interface Running {
  events: DebateEvent[];
  clients: Set<ServerResponse>;
  controller: AbortController;
}
const running = new Map<number, Running>();
/** Oltre questo numero il dibattito diventa lento e consuma quote senza aggiungere idee nuove. */
const MAX_PARTICIPANTS = 10;

const CLAUDE_MODELS = ["sonnet", "opus", "haiku"];
const DEFAULT_ROUNDS: Rounds = 3;
const DEFAULT_JUDGE = "claude";

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

/** Errore dovuto alla richiesta del client: diventa una risposta 4xx, non un 500. */
class BadRequest extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  let s = "";
  for await (const chunk of req) {
    s += chunk;
    if (s.length > 100_000) throw new BadRequest(413, "richiesta troppo grande");
  }
  try { return JSON.parse(s || "{}"); } catch { throw new BadRequest(400, "JSON non valido"); }
}

function send(r: Running, e: DebateEvent) {
  r.events.push(e);
  const line = `data: ${JSON.stringify(e)}\n\n`;
  for (const c of r.clients) c.write(line);
}

async function handle(req: IncomingMessage, res: ServerResponse) {
  // Accetta solo richieste dirette a localhost (protezione da DNS rebinding).
  const host = (req.headers.host ?? "").split(":")[0];
  if (host !== "localhost" && host !== "127.0.0.1") return json(res, 403, { error: "host non consentito" });

  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const path = url.pathname;
  const idMatch = path.match(/^\/api\/debates\/(\d+)(\/events|\/cancel)?$/);

  if (req.method === "GET" && path === "/api/models") {
    return json(res, 200, {
      judge: config.judge.label,
      native: process.env.COUNCIL_PARENT === "app",
      checking: isChecking(),
      claudeModels: CLAUDE_MODELS,
      defaults: { rounds: DEFAULT_ROUNDS, judge: DEFAULT_JUDGE, claudeModel: config.judge.model },
      models: config.models.map((m) => ({
        id: m.id, label: m.label, default: !!m.default, available: isAvailable(m),
        provider: m.provider ?? "abbonamento", model: m.model, health: getHealth(m.id),
      })),
    });
  }

  // ---- Impostazioni: provider, catalogo, prova, selezione ----
  const isJsonPost = () => String(req.headers["content-type"]).startsWith("application/json");

  if (req.method === "GET" && path === "/api/providers") {
    return json(res, 200, Object.entries(config.providers).map(([id, p]) => ({
      id, name: p.name ?? id, hasKey: Boolean(process.env[p.keyEnv]?.trim()),
    })));
  }

  const catMatch = path.match(/^\/api\/catalog\/([a-z0-9-]+)$/);
  if (req.method === "GET" && catMatch) {
    try {
      return json(res, 200, await listCatalog(catMatch[1], url.searchParams.has("fresh")));
    } catch (e) {
      return json(res, 502, { error: (e as Error).message });
    }
  }

  if (req.method === "POST" && path === "/api/probe") {
    if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
    const b = (await readBody(req)) as { provider?: string; model?: string };
    if (!b.provider || !b.model) return json(res, 400, { error: "provider e model obbligatori" });
    return json(res, 200, await probe(b.provider, b.model));
  }

  if (req.method === "GET" && path === "/api/selection") return json(res, 200, selection);

  if (req.method === "PUT" && path === "/api/selection") {
    if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
    try {
      // Salvata su disco: diventa attiva al riavvio del motore (l'app lo fa subito dopo).
      saveSelection(validateSelection(await readBody(req)));
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 400, { error: (e as Error).message });
    }
  }

  if (req.method === "POST" && path === "/api/health") {
    if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
    runHealthCheck(true); // richiesta esplicita: riprova davvero i modelli
    return json(res, 202, { ok: true });
  }

  if (req.method === "GET" && path === "/api/debates") return json(res, 200, listDebates(50, url.searchParams.get("q") ?? undefined));

  if (req.method === "POST" && path === "/api/debates") {
    // Solo JSON: impedisce a pagine esterne di avviare dibattiti con un semplice form.
    if (!String(req.headers["content-type"]).startsWith("application/json")) return json(res, 415, { error: "serve JSON" });
    const body = (await readBody(req)) as {
      question?: string; models?: string[]; rounds?: unknown; claudeModel?: unknown; judge?: unknown; parentId?: unknown;
    };
    if (body === null || typeof body !== "object" || Array.isArray(body)) return json(res, 400, { error: "corpo della richiesta non valido" });
    if (body.models !== undefined && !Array.isArray(body.models)) return json(res, 400, { error: "models deve essere un elenco" });
    const question = String(body.question ?? "").trim();
    if (question.length > 20_000) return json(res, 400, { error: "domanda troppo lunga (max 20.000 caratteri)" });
    // Id duplicati ignorati: lo stesso modello due volte non aggiunge una voce nuova.
    const ids = [...new Set((body.models ?? []).filter((x): x is string => typeof x === "string"))];
    const defs = ids.map(findModel).filter((m) => m && isAvailable(m)) as NonNullable<ReturnType<typeof findModel>>[];
    if (!question) return json(res, 400, { error: "domanda vuota" });
    if (defs.length < 2) return json(res, 400, { error: "seleziona almeno 2 modelli disponibili" });
    if (defs.length > MAX_PARTICIPANTS) return json(res, 400, { error: `massimo ${MAX_PARTICIPANTS} partecipanti` });

    const rounds = body.rounds ?? DEFAULT_ROUNDS;
    if (typeof rounds !== "number" || !Number.isInteger(rounds) || rounds < 0 || rounds > 3) {
      return json(res, 400, { error: "rounds deve essere 0, 1, 2 o 3" });
    }
    const claudeModel = body.claudeModel ?? config.judge.model;
    if (typeof claudeModel !== "string" || !CLAUDE_MODELS.includes(claudeModel)) {
      return json(res, 400, { error: `claudeModel deve essere uno tra: ${CLAUDE_MODELS.join(", ")}` });
    }
    const judgeId = body.judge ?? DEFAULT_JUDGE;
    const judgeDef = judgeId === DEFAULT_JUDGE
      ? config.judge
      : typeof judgeId === "string" ? config.models.find((m) => m.id === judgeId && isAvailable(m)) : undefined;
    if (!judgeDef) return json(res, 400, { error: "giudice non valido o non disponibile" });

    let parentContext: { id: number; question: string; verdict: string } | undefined;
    if (body.parentId !== undefined && body.parentId !== null) {
      const pid = body.parentId;
      const parent = typeof pid === "number" && Number.isInteger(pid) ? getDebate(pid) : undefined;
      if (!parent) return json(res, 400, { error: "dibattito precedente non trovato" });
      if (parent.status !== "done" || !parent.verdict) return json(res, 400, { error: "il dibattito precedente non è concluso" });
      parentContext = { id: parent.id, question: parent.question, verdict: parent.verdict };
    }

    const id = createDebate(
      question, defs.map((d) => d.id),
      { rounds, judge: judgeDef.id, claudeModel },
      parentContext?.id ?? null,
    );
    const r: Running = { events: [], clients: new Set(), controller: new AbortController() };
    running.set(id, r);
    const opts = { rounds: rounds as Rounds, judge: judgeDef, claudeModel, parentContext };
    runDebate(id, question, defs, opts, (e) => send(r, e), r.controller.signal).finally(() => {
      for (const c of r.clients) c.end();
      // Tiene gli eventi in memoria ancora un po' per chi si ricollega.
      setTimeout(() => running.delete(id), 60_000);
    });
    return json(res, 201, { id });
  }

  if (idMatch) {
    const id = Number(idMatch[1]);
    const sub = idMatch[2];

    if (req.method === "GET" && sub === "/events") {
      const r = running.get(id);
      if (!r) return json(res, 404, { error: "dibattito non in corso" });
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
      for (const e of r.events) res.write(`data: ${JSON.stringify(e)}\n\n`);
      if (r.events.some((e) => e.type === "done")) return res.end();
      r.clients.add(res);
      req.on("close", () => r.clients.delete(res));
      return;
    }

    if (req.method === "POST" && sub === "/cancel") {
      // Solo JSON: una pagina esterna non può annullare un dibattito con un semplice form.
      if (!String(req.headers["content-type"]).startsWith("application/json")) return json(res, 415, { error: "serve JSON" });
      running.get(id)?.controller.abort();
      return json(res, 200, { ok: true });
    }

    if (req.method === "GET" && !sub) {
      const d = getDebate(id);
      return d ? json(res, 200, { ...d, live: running.has(id) && d.status === "running" }) : json(res, 404, { error: "non trovato" });
    }

    if (req.method === "DELETE" && !sub) {
      if (running.has(id)) running.get(id)!.controller.abort();
      deleteDebate(id);
      return json(res, 200, { ok: true });
    }
  }

  json(res, 404, { error: "non trovato" });
}

createServer((req, res) => {
  handle(req, res).catch((e) => {
    if (!res.headersSent) json(res, e instanceof BadRequest ? e.status : 500, { error: (e as Error).message });
    else res.end();
  });
}).listen(PORT, "127.0.0.1", function (this: import("node:net").Server) {
  const addr = this.address();
  const port = typeof addr === "object" && addr ? addr.port : PORT;
  const on = config.models.filter(isAvailable).map((m) => m.label);
  // Riga letta dall'app Mac per sapere su quale porta collegarsi (PORT=0 = porta libera a caso).
  console.log(`COUNCIL_PORT=${port}`);
  console.log(`Motore Conclave pronto su http://localhost:${port} (solo API)`);
  console.log(`Modelli disponibili (${on.length}): ${on.join(", ")}`);
  // Controllo all'avvio in background: l'interfaccia mostra lo stato man mano.
  runHealthCheck().then(() => {
    for (const m of config.models) {
      const h = getHealth(m.id);
      console.log(`  ${m.label}: ${h.status}${h.note ? ` — ${h.note}` : ""}`);
    }
  });
});

// Avviato dall'app Mac: se l'app si chiude (anche per crash) lo stdin si chiude e il server termina.
if (process.env.COUNCIL_PARENT === "app") {
  process.stdin.resume();
  process.stdin.on("end", () => process.exit(0));
}
