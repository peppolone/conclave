import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { config, isAvailable, findModel, PORT, selection, validateSelection, saveSelection, type ModelDef } from "./config.ts";
import { medianMsByModel, JUDGE_KEY, createDebate, listDebates, getDebate, deleteDebate, saveAttachments, saveMessage, nextTurn, hasTurnZeroContent, startTurn } from "./db.ts";
import { runDebate, runQuickAnswer, type DebateEvent, type Rounds } from "./debate/orchestrator.ts";
import { buildConversation } from "./debate/followup.ts";
import type { Attachment } from "./debate/prompts.ts";
import { findResearcher } from "./debate/research.ts";
import { listCatalog, probe } from "./catalog.ts";
import { getHealth, runHealthCheck, isChecking } from "./health.ts";
import { engineToken } from "./bootstrap.ts";
import { redact, redactProcessOutput } from "./redact.ts";
import { killClaudeChildren } from "./adapters/claude-cli.ts";

redactProcessOutput();

/**
 * Lavoro in corso di una discussione: il dibattito (turno 0) o un turno successivo. Una voce per
 * discussione: un turno nuovo la sostituisce, quindi chi si collega a /events riceve solo gli
 * eventi del turno in corso (o dell'ultimo, per 60 s dopo la fine).
 */
interface Running {
  turn: number;
  events: DebateEvent[];
  clients: Set<ServerResponse>;
  controller: AbortController;
  finished: boolean;
}
const running = new Map<number, Running>();
/** Oltre questo numero il dibattito diventa lento e consuma quote senza aggiungere idee nuove. */
const MAX_PARTICIPANTS = 10;
const SSE_PING_MS = 10_000;
/** Corpo massimo di una richiesta: domanda + allegati (60.000 caratteri) con il margine dell'escape JSON. */
const MAX_BODY = 400_000;

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

/** Token dell'app (vedi bootstrap.ts): confronto a tempo costante. */
function authorized(req: IncomingMessage): boolean {
  if (!engineToken) return true;
  const got = Buffer.from(String(req.headers.authorization ?? ""));
  const want = Buffer.from(`Bearer ${engineToken}`);
  return got.length === want.length && timingSafeEqual(got, want);
}

/** Un errore imprevisto in un lavoro in background si registra: non deve chiudere il motore. */
const logError = (what: string) => (e: unknown) => console.error(`Errore (${what}): ${(e as Error)?.message ?? e}`);

async function readBody(req: IncomingMessage): Promise<unknown> {
  let s = "";
  // Decodifica continua: un carattere accentato a cavallo di due pacchetti non si rovina.
  req.setEncoding("utf8");
  for await (const chunk of req) {
    s += chunk;
    if (s.length > MAX_BODY) throw new BadRequest(413, "richiesta troppo grande");
  }
  try { return JSON.parse(s || "{}"); } catch { throw new BadRequest(400, "JSON non valido"); }
}

/** Corpo JSON che deve essere un oggetto (non null, non elenco). */
async function readObject(req: IncomingMessage): Promise<Record<string, unknown>> {
  const b = await readBody(req);
  if (b === null || typeof b !== "object" || Array.isArray(b)) throw new BadRequest(400, "corpo della richiesta non valido");
  return b as Record<string, unknown>;
}

function send(r: Running, e: DebateEvent) {
  r.events.push(e);
  const line = `data: ${JSON.stringify(e)}\n\n`;
  for (const c of r.clients) c.write(line);
}

/** Registra il lavoro di una discussione e, alla fine, chiude i flussi e lo toglie dopo 60 s. */
function track(id: number, turn: number, work: (r: Running) => Promise<void>): void {
  const r: Running = { turn, events: [], clients: new Set(), controller: new AbortController(), finished: false };
  running.set(id, r);
  work(r).catch(logError(turn ? `discussione ${id}, turno ${turn}` : `dibattito ${id}`)).finally(() => {
    r.finished = true;
    for (const c of r.clients) c.end();
    // Tiene gli eventi in memoria ancora un po' per chi si ricollega; un turno nuovo nel frattempo
    // ha già sostituito la voce e non va tolto.
    setTimeout(() => { if (running.get(id) === r) running.delete(id); }, 60_000);
  });
}

// ---- Validazione di POST /api/debates ----

const MAX_QUESTION = 20_000;
const MAX_ATTACHMENTS = 5;
const MAX_ATTACHMENT_TEXT = 40_000;
const MAX_ATTACHMENTS_TOTAL = 60_000;
const MAX_ATTACHMENT_NAME = 200;
const ATTACHMENT_KINDS = ["pdf", "text", "image"] as const;

interface DebateRequest {
  question: string;
  models: ModelDef[];
  rounds: Rounds;
  judge: ModelDef;
  claudeModel: string;
  parentContext?: { id: number; question: string; verdict: string };
  webSearch: boolean;
  attachments: Attachment[];
}

const fmt = (n: number) => n.toLocaleString("it-IT");

/** Allegati: testo già estratto dall'app. Lunghezze in unità UTF-16 (String.length, come la domanda). */
function parseAttachments(raw: unknown): Attachment[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) throw new BadRequest(400, "attachments deve essere un elenco");
  if (raw.length > MAX_ATTACHMENTS) throw new BadRequest(400, `massimo ${MAX_ATTACHMENTS} allegati`);
  let total = 0;
  return raw.map((a, i) => {
    if (a === null || typeof a !== "object" || Array.isArray(a)) throw new BadRequest(400, `allegato ${i + 1} non valido`);
    const { name, kind, text } = a as Record<string, unknown>;
    if (typeof name !== "string" || typeof text !== "string") throw new BadRequest(400, `allegato ${i + 1}: name e text devono essere testi`);
    if (!ATTACHMENT_KINDS.includes(kind as Attachment["kind"])) throw new BadRequest(400, `allegato ${i + 1}: kind deve essere pdf, text o image`);
    if (name.length > MAX_ATTACHMENT_NAME) throw new BadRequest(400, `allegato ${i + 1}: nome troppo lungo (max ${MAX_ATTACHMENT_NAME} caratteri)`);
    if (text.length > MAX_ATTACHMENT_TEXT) throw new BadRequest(400, `allegato ${i + 1}: testo troppo lungo (max ${fmt(MAX_ATTACHMENT_TEXT)} caratteri)`);
    total += text.length;
    if (total > MAX_ATTACHMENTS_TOTAL) throw new BadRequest(400, `allegati troppo lunghi in totale (max ${fmt(MAX_ATTACHMENTS_TOTAL)} caratteri)`);
    // Il nome finisce in un'intestazione del prompt: una riga sola, senza caratteri di controllo.
    const clean = name.replace(/[\p{Cc}\p{Zl}\p{Zp}]+/gu, " ").replace(/^[#\s]+/, "").trim();
    return { name: clean || `allegato ${i + 1}`, kind: kind as Attachment["kind"], text: text.replace(/\u0000/g, "") };
  });
}

// Parti comuni a POST /api/debates e POST /api/debates/:id/followups.

function parseQuestion(body: Record<string, unknown>): string {
  const question = String(body.question ?? "").trim();
  if (question.length > MAX_QUESTION) throw new BadRequest(400, `domanda troppo lunga (max ${fmt(MAX_QUESTION)} caratteri)`);
  if (!question) throw new BadRequest(400, "domanda vuota");
  return question;
}

function parseModels(body: Record<string, unknown>): ModelDef[] {
  if (body.models !== undefined && !Array.isArray(body.models)) throw new BadRequest(400, "models deve essere un elenco");
  // Id duplicati ignorati: lo stesso modello due volte non aggiunge una voce nuova.
  const ids = [...new Set(((body.models as unknown[] | undefined) ?? []).filter((x): x is string => typeof x === "string"))];
  const models = ids.map(findModel).filter((m): m is ModelDef => !!m && isAvailable(m));
  if (models.length < 2) throw new BadRequest(400, "seleziona almeno 2 modelli disponibili");
  if (models.length > MAX_PARTICIPANTS) throw new BadRequest(400, `massimo ${MAX_PARTICIPANTS} partecipanti`);
  return models;
}

function parseRounds(body: Record<string, unknown>): Rounds {
  const rounds = body.rounds ?? DEFAULT_ROUNDS;
  if (typeof rounds !== "number" || !Number.isInteger(rounds) || rounds < 0 || rounds > 3) {
    throw new BadRequest(400, "rounds deve essere 0, 1, 2 o 3");
  }
  return rounds as Rounds;
}

function parseClaudeModel(body: Record<string, unknown>): string {
  const claudeModel = body.claudeModel ?? config.judge.model;
  if (typeof claudeModel !== "string" || !CLAUDE_MODELS.includes(claudeModel)) {
    throw new BadRequest(400, `claudeModel deve essere uno tra: ${CLAUDE_MODELS.join(", ")}`);
  }
  return claudeModel;
}

/** Giudice (o risponditore): "claude" = giudice predefinito, altrimenti un modello disponibile. */
function parseJudge(value: unknown, what: string): ModelDef {
  const id = value ?? DEFAULT_JUDGE;
  const judge = id === DEFAULT_JUDGE
    ? config.judge
    : typeof id === "string" ? config.models.find((m) => m.id === id && isAvailable(m)) : undefined;
  if (!judge) throw new BadRequest(400, `${what} non valido o non disponibile`);
  return judge;
}

function parseWebSearch(body: Record<string, unknown>): boolean {
  if (body.webSearch !== undefined && body.webSearch !== null && typeof body.webSearch !== "boolean") {
    throw new BadRequest(400, "webSearch deve essere true o false");
  }
  return body.webSearch === true;
}

/** Controlla e normalizza la richiesta di un nuovo dibattito: ogni problema è un 400, mai un 500. */
function parseDebateRequest(body: Record<string, unknown>): DebateRequest {
  const models = parseModels(body);
  const question = parseQuestion(body);
  const rounds = parseRounds(body);
  const claudeModel = parseClaudeModel(body);
  const judge = parseJudge(body.judge, "giudice");

  let parentContext: DebateRequest["parentContext"];
  if (body.parentId !== undefined && body.parentId !== null) {
    const pid = body.parentId;
    const parent = typeof pid === "number" && Number.isInteger(pid) ? getDebate(pid) : undefined;
    if (!parent) throw new BadRequest(400, "dibattito precedente non trovato");
    if (parent.status !== "done" || !parent.verdict) throw new BadRequest(400, "il dibattito precedente non è concluso");
    // Solo domanda e verdetto: gli allegati della discussione madre non passano all'approfondimento.
    parentContext = { id: parent.id, question: parent.question, verdict: parent.verdict };
  }

  const webSearch = parseWebSearch(body);
  const attachments = parseAttachments(body.attachments);
  return { question, models, rounds, judge, claudeModel, parentContext, webSearch, attachments };
}

type FollowupRequest =
  | { mode: "quick"; question: string; responder: ModelDef; claudeModel: string; webSearch: boolean; attachments: Attachment[] }
  | { mode: "council"; question: string; models: ModelDef[]; rounds: Rounds; judge: ModelDef; claudeModel: string; webSearch: boolean; attachments: Attachment[] };

/** Domanda di seguito: stessi limiti di POST /api/debates. In modo "quick" models/rounds/judge si ignorano. */
function parseFollowupRequest(body: Record<string, unknown>): FollowupRequest {
  const mode = body.mode ?? "quick";
  if (mode !== "quick" && mode !== "council") throw new BadRequest(400, "mode deve essere quick o council");
  const question = parseQuestion(body);
  const claudeModel = parseClaudeModel(body);
  const webSearch = parseWebSearch(body);
  const attachments = parseAttachments(body.attachments);
  if (mode === "quick") return { mode, question, responder: parseJudge(body.responder, "risponditore"), claudeModel, webSearch, attachments };
  return { mode, question, models: parseModels(body), rounds: parseRounds(body), judge: parseJudge(body.judge, "giudice"), claudeModel, webSearch, attachments };
}

async function handle(req: IncomingMessage, res: ServerResponse) {
  // Accetta solo richieste dirette a localhost (protezione da DNS rebinding).
  const host = (req.headers.host ?? "").split(":")[0];
  if (host !== "localhost" && host !== "127.0.0.1") return json(res, 403, { error: "host non consentito" });
  // Solo l'app che ha avviato il motore: non altri processi locali né pagine web.
  if (!authorized(req)) return json(res, 401, { error: "non autorizzato" });

  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const path = url.pathname;
  const idMatch = path.match(/^\/api\/debates\/(\d+)(\/events|\/cancel|\/followups)?$/);

  if (req.method === "GET" && path === "/api/models") {
    const researcher = findResearcher();
    const medians = medianMsByModel();
    return json(res, 200, {
      judge: config.judge.label,
      native: process.env.COUNCIL_PARENT === "app",
      checking: isChecking(),
      claudeModels: CLAUDE_MODELS,
      defaults: { rounds: DEFAULT_ROUNDS, judge: DEFAULT_JUDGE, claudeModel: config.judge.model },
      models: config.models.map((m) => ({
        id: m.id, label: m.label, default: !!m.default, available: isAvailable(m),
        provider: m.provider ?? "abbonamento", model: m.model, health: getHealth(m.id), avgMs: medians.get(m.id) ?? null,
      })),
      // Tempi tipici (mediana degli ultimi 20 riusciti): null se non ci sono dati.
      judgeAvgMs: medians.get(JUDGE_KEY) ?? null,
      webSearch: { available: researcher !== null, via: researcher?.via ?? null },
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
      return json(res, 502, { error: redact((e as Error).message) });
    }
  }

  if (req.method === "POST" && path === "/api/probe") {
    if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
    const b = await readObject(req);
    if (typeof b.provider !== "string" || typeof b.model !== "string" || !b.provider || !b.model) return json(res, 400, { error: "provider e model obbligatori" });
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
    runHealthCheck(true).catch(logError("controllo dei modelli")); // richiesta esplicita: riprova davvero i modelli
    return json(res, 202, { ok: true });
  }

  if (req.method === "GET" && path === "/api/debates") return json(res, 200, listDebates(50, url.searchParams.get("q") ?? undefined));

  if (req.method === "POST" && path === "/api/debates") {
    // Solo JSON: impedisce a pagine esterne di avviare dibattiti con un semplice form.
    if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
    const d = parseDebateRequest(await readObject(req));
    const id = createDebate(
      d.question, d.models.map((m) => m.id),
      { rounds: d.rounds, judge: d.judge.id, claudeModel: d.claudeModel, ...(d.webSearch ? { webSearch: true } : {}) },
      d.parentContext?.id ?? null,
    );
    if (d.attachments.length) saveAttachments(id, d.attachments);
    const opts = {
      rounds: d.rounds, judge: d.judge, claudeModel: d.claudeModel, parentContext: d.parentContext,
      webSearch: d.webSearch, attachments: d.attachments,
    };
    track(id, 0, (r) => runDebate(id, d.question, d.models, opts, (e) => send(r, e), r.controller.signal));
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
      // Commento SSE periodico: durante un giudice lento il flusso non resta muto per minuti.
      const ping = setInterval(() => { if (!res.writableEnded) res.write(": ping\n\n"); }, SSE_PING_MS);
      res.on("close", () => clearInterval(ping));
      req.on("close", () => { clearInterval(ping); r.clients.delete(res); });
      return;
    }

    if (req.method === "POST" && sub === "/followups") {
      if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
      const body = await readObject(req);
      // Da qui a startTurn nessun await: due richieste insieme non aprono due turni.
      const debate = getDebate(id);
      if (!debate) return json(res, 404, { error: "non trovato" });
      const live = running.get(id);
      if (debate.status === "running" || (live && !live.finished)) return json(res, 409, { error: "la discussione è ancora in corso" });
      const f = parseFollowupRequest(body);
      if (!hasTurnZeroContent(id)) throw new BadRequest(400, "il dibattito originale non ha né un verdetto né una risposta");

      const turn = nextTurn(id);
      // Prima di segnare la discussione in corso: un errore qui non la lascia bloccata su "running".
      const conversation = buildConversation(id, debate.question, turn);
      startTurn(id);
      const save = (model_id: string, phase: string, content: string) => saveMessage(id, { model_id, phase, content, error: null, ms: null, turn });
      save("_user", "followup", f.question);
      save("_meta", "turn", JSON.stringify(f.mode === "quick"
        ? { mode: f.mode, rounds: 0, judge: f.responder.id, webSearch: f.webSearch }
        : { mode: f.mode, rounds: f.rounds, judge: f.judge.id, webSearch: f.webSearch }));
      if (f.attachments.length) saveAttachments(id, f.attachments, turn);
      track(id, turn, (r) => {
        const emit = (e: DebateEvent) => send(r, e);
        emit({ type: "turn", turn, question: f.question, mode: f.mode });
        if (f.mode === "quick") {
          if (f.attachments.length) {
            const meta = f.attachments.map((a) => ({ name: a.name, kind: a.kind, chars: a.text.length }));
            save("_attachments", "start", JSON.stringify(meta));
          }
          // Riserve dopo Claude: i partecipanti del dibattito originale ancora disponibili.
          const fallbacks = debate.models.map(findModel).filter((m): m is ModelDef => !!m && isAvailable(m));
          return runQuickAnswer(id, turn, f.question, {
            responder: f.responder, claudeModel: f.claudeModel, fallbacks, webSearch: f.webSearch,
            attachments: f.attachments, conversation,
          }, emit, r.controller.signal);
        }
        return runDebate(id, f.question, f.models, {
          rounds: f.rounds, judge: f.judge, claudeModel: f.claudeModel, webSearch: f.webSearch,
          attachments: f.attachments, turn, conversation,
        }, emit, r.controller.signal);
      });
      return json(res, 201, { turn });
    }

    if (req.method === "POST" && sub === "/cancel") {
      // Solo JSON: una pagina esterna non può annullare un dibattito con un semplice form.
      if (!isJsonPost()) return json(res, 415, { error: "serve JSON" });
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
    if (!res.headersSent) json(res, e instanceof BadRequest ? e.status : 500, { error: redact((e as Error).message) });
    else res.end();
  });
}).listen(PORT, "127.0.0.1", function (this: import("node:net").Server) {
  const addr = this.address();
  const port = typeof addr === "object" && addr ? addr.port : PORT;
  const on = config.models.filter(isAvailable).map((m) => m.label);
  // Riga letta dall'app Mac per sapere su quale porta collegarsi (PORT=0 = porta libera a caso).
  console.log(`COUNCIL_PORT=${port}`);
  console.log(`Motore Conclave pronto su http://localhost:${port} (solo API${engineToken ? ", con token" : ", senza token: solo sviluppo"})`);
  console.log(`Modelli disponibili (${on.length}): ${on.join(", ")}`);
  // Controllo all'avvio in background: l'interfaccia mostra lo stato man mano.
  runHealthCheck().then(() => {
    for (const m of config.models) {
      const h = getHealth(m.id);
      console.log(`  ${m.label}: ${h.status}${h.note ? ` — ${h.note}` : ""}`);
    }
  }).catch(logError("controllo dei modelli"));
});

/** Chiusura ordinata: ferma i dibattiti e i processi `claude` ancora in corso, poi esce. */
function shutdown() {
  for (const r of running.values()) r.controller.abort();
  killClaudeChildren();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

// Avviato dall'app Mac: se l'app si chiude (anche per crash) lo stdin si chiude e il server termina.
if (process.env.COUNCIL_PARENT === "app") {
  process.stdin.resume();
  process.stdin.on("end", shutdown);
}
