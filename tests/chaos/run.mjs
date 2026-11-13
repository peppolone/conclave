// Test di stress del motore ("cerca di rompere le cose").
// Uso: npm run test:chaos   (oppure node tests/chaos/run.mjs [lettere scenari, es. "a,d,j"])
//
// Avvia il provider finto e il motore con dati e configurazione temporanei, esegue gli
// scenari via API e stampa PASS/FAIL. Non usa mai Claude e non tocca la cartella dati reale.

import { spawn } from "node:child_process";
import { request } from "node:http";
import { connect } from "node:net";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm, writeFile, stat, readdir, chmod } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { MODELS, FAKE_GOOGLE_KEY, DOSSIER_MARK, DOSSIER_URL } from "./mock-provider.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");
const MIN = 60_000;

let mock, engine, dataDir, enginePort, mockPort;
/** Token dell'API del motore, passato sullo stdin come fa l'app. */
const TOKEN = randomBytes(32).toString("hex");
const CHAOS_KEY = "chaos-test-key-0123456789";
/** Chiave incollata male (a capo in mezzo): fetch fallisce prima di partire e ripete l'intestazione. */
const BAD_KEY_TAIL = "secret-ABCDEF0123456789";
const CHAOS_BAD_KEY = `chaos-bad\n${BAD_KEY_TAIL}`;
let cleaned = false;
/** Motori e cartelle in più avviati dagli scenari sulle chiavi dall'app (w, x). */
const extraProcs = [];
const extraDirs = [];

// ---------- avvio e chiusura ----------

function startProcess(cmd, args, env, marker, stdinLine) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { cwd: ROOT, env, stdio: ["pipe", "pipe", "pipe"] });
    if (stdinLine) p.stdin.write(stdinLine + "\n");
    let buf = "";
    const log = [];
    p.log = log;
    const timer = setTimeout(() => reject(new Error(`${args.join(" ")}: nessuna riga ${marker} entro 20 s`)), 20_000);
    p.stdout.on("data", (d) => {
      buf += d;
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const l of lines) {
        log.push(l);
        if (log.length > 200) log.shift();
        const m = l.match(new RegExp(`^${marker}=(\\d+)`));
        if (m) { clearTimeout(timer); resolve({ proc: p, port: Number(m[1]) }); }
      }
    });
    p.stderr.on("data", (d) => { log.push(`[stderr] ${String(d).trim()}`); if (log.length > 200) log.shift(); });
    p.on("exit", (code) => { clearTimeout(timer); p.exited = code ?? "signal"; reject(new Error(`${args[args.length - 1]} terminato (${code})`)); });
  });
}

async function cleanup() {
  if (cleaned) return;
  cleaned = true;
  for (const p of [engine, mock, ...extraProcs]) {
    if (p && p.exitCode === null && !p.killed) p.kill("SIGTERM");
  }
  for (const d of [dataDir, ...extraDirs]) if (d) await rm(d, { recursive: true, force: true }).catch(() => {});
}

process.on("SIGINT", async () => { console.log("\nInterrotto: chiudo mock e motore."); await cleanup(); process.exit(130); });
process.on("SIGTERM", async () => { await cleanup(); process.exit(143); });

// ---------- HTTP ----------

function api(method, path, { body, headers = {}, port = enginePort, raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : raw ? String(body) : JSON.stringify(body);
    const h = { Host: `127.0.0.1:${port}`, ...(port === enginePort ? { Authorization: `Bearer ${TOKEN}` } : {}), ...headers };
    if (data !== undefined) {
      h["Content-Length"] = Buffer.byteLength(data);
      if (!Object.keys(h).some((k) => k.toLowerCase() === "content-type")) h["Content-Type"] = "application/json";
    }
    const req = request({ host: "127.0.0.1", port, method, path, headers: h, timeout: 30_000 }, (res) => {
      let s = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (s += c));
      res.on("end", () => {
        let j = null;
        try { j = JSON.parse(s); } catch { /* non JSON */ }
        resolve({ status: res.statusCode, body: j, text: s });
      });
    });
    req.on("timeout", () => req.destroy(new Error(`timeout ${method} ${path}`)));
    req.on("error", reject);
    if (data !== undefined) req.write(data);
    req.end();
  });
}

/** Segue gli eventi SSE di un dibattito fino all'evento "done" o alla scadenza. */
function followEvents(id, timeoutMs) {
  return new Promise((resolve) => {
    const events = [];
    let finished = false;
    const finish = (timedOut) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      req.destroy();
      resolve({ events, timedOut });
    };
    const timer = setTimeout(() => finish(true), timeoutMs);
    const req = request({ host: "127.0.0.1", port: enginePort, path: `/api/debates/${id}/events`, headers: { Host: `127.0.0.1:${enginePort}`, Authorization: `Bearer ${TOKEN}` } }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return finish(false); }
      let buf = "";
      res.setEncoding("utf8");
      res.on("data", (c) => {
        buf += c;
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const chunk = buf.slice(0, i);
          buf = buf.slice(i + 2);
          for (const line of chunk.split("\n")) {
            if (!line.startsWith("data: ")) continue;
            try {
              const e = JSON.parse(line.slice(6));
              events.push(e);
              if (e.type === "done") return finish(false);
            } catch { /* riga non JSON */ }
          }
        }
      });
      res.on("end", () => finish(false));
      res.on("error", () => finish(false));
    });
    req.on("error", () => finish(false));
    req.end();
  });
}

/** Attende che lo stato salvato non sia più "running" (dopo l'evento done può servire un attimo). */
async function finalState(id, waitMs = 5000) {
  const until = Date.now() + waitMs;
  for (;;) {
    const r = await api("GET", `/api/debates/${id}`);
    if (r.status !== 200) return r.body;
    if (r.body.status !== "running" || Date.now() > until) return r.body;
    await new Promise((res) => setTimeout(res, 300));
  }
}

// ---------- utilità per gli scenari ----------

const QUESTION = (tag) => `[scenario:${tag}] Conviene usare il treno o l'aereo per Roma–Milano?`;

async function debate(tag, models, rounds, judge, timeoutMs, { onStart, extra } = {}) {
  const started = Date.now();
  const r = await api("POST", "/api/debates", { body: { question: QUESTION(tag), models, rounds, judge, claudeModel: "sonnet", ...extra } });
  if (r.status !== 201) throw new Error(`POST /api/debates → ${r.status} ${r.text.slice(0, 150)}`);
  const id = r.body.id;
  onStart?.(id);
  const { events, timedOut } = await followEvents(id, timeoutMs);
  const state = await finalState(id);
  return { id, events, timedOut, state, secs: (Date.now() - started) / 1000 };
}

const msgs = (state, modelId, phase) =>
  (state?.messages ?? []).filter((m) => m.model_id === modelId && (!phase || m.phase === phase));
const okMsgs = (state, modelId, phase) => msgs(state, modelId, phase).filter((m) => m.content && !m.error);
const errMsgs = (state, modelId) => msgs(state, modelId).filter((m) => m.error);
const verdictRow = (state) => (state?.messages ?? []).find((m) => m.phase === "verdict" && m.content);
const doneEvent = (events) => events.find((e) => e.type === "done");

function expectDone(res, maxSecs) {
  if (res.timedOut) return `nessun evento done entro ${maxSecs} s (stato ${res.state?.status})`;
  if (res.state?.status !== "done") {
    const d = doneEvent(res.events);
    return `stato "${res.state?.status}"${d?.error ? `: ${d.error}` : ""}`;
  }
  if (!res.state.verdict) return "stato done ma verdetto vuoto";
  return null;
}

// ---------- scenari ----------

const PHASES = ["initial", "critique", "revise", "final"];

const SCENARIOS = {
  async a() {
    const max = 120;
    const r = await debate("a", ["ok-a", "ok-b"], 3, "ok-a", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, bad, r.secs];
    const missing = [];
    for (const m of ["ok-a", "ok-b"]) for (const p of PHASES) if (!okMsgs(r.state, m, p).length) missing.push(`${m}/${p}`);
    if (missing.length) return [false, `messaggi mancanti: ${missing.join(", ")}`, r.secs];
    const all = r.state.messages.filter((m) => m.content).map((m) => m.content).join("");
    const info = `U+202F ${all.includes(" ") ? "presente" : "assente"}, U+2011 ${all.includes("‑") ? "presente" : "assente"} nel testo salvato`;
    return [true, `done, 4 fasi per entrambi, verdetto di ${verdictRow(r.state)?.model_id} (${info})`, r.secs];
  },

  // Un modello bloccato non deve fermare gli altri: ok-a e ok-b discutono tutti i round.
  async b() {
    const max = 240;
    const r = await debate("b", ["ok-a", "ok-b", "hang"], 2, "ok-b", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, `${bad} dopo ${r.secs.toFixed(0)} s`, r.secs];
    const phases = ["initial", "critique", "revise"];
    const missing = [];
    for (const m of ["ok-a", "ok-b"]) for (const p of phases) if (!okMsgs(r.state, m, p).length) missing.push(`${m}/${p}`);
    if (missing.length) {
      const herr = errMsgs(r.state, "hang").map((m) => `${m.phase}: ${m.error.slice(0, 60)}`).join("; ");
      return [false, `done ma messaggi mancanti: ${missing.join(", ")} (errori hang → ${herr || "nessuno"})`, r.secs];
    }
    return [true, `done in ${r.secs.toFixed(0)} s, ok-a e ok-b in tutte le fasi, hang escluso`, r.secs];
  },

  // Se resta un solo modello i round si saltano, ma va detto (nota salvata nella cronologia).
  async b2() {
    const max = 120;
    const r = await debate("b2", ["ok-a", "crash500"], 2, "ok-b", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, `${bad} dopo ${r.secs.toFixed(0)} s`, r.secs];
    const note = r.state.messages.find((m) => m.model_id === "_note");
    if (!note) return [false, "done ma nessuna nota sui round saltati", r.secs];
    return [true, `done, nota presente: "${note.content.slice(0, 50)}"`, r.secs];
  },

  async c() {
    const max = 240;
    const r = await debate("c", ["ok-a", "flaky-critique"], 3, "ok-a", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, bad, r.secs];
    const back = okMsgs(r.state, "flaky-critique", "revise").length + okMsgs(r.state, "flaky-critique", "final").length;
    const failedR1 = errMsgs(r.state, "flaky-critique").some((m) => m.phase === "critique");
    if (!back) {
      return [false, `flaky-critique non rientra dopo il round 1 (errore in critique: ${failedR1 ? "sì" : "no"}; fasi con messaggi: ${
        PHASES.filter((p) => okMsgs(r.state, "flaky-critique", p).length).join(", ") || "nessuna"})`, r.secs];
    }
    return [true, `done, flaky-critique rientra (critique fallita: ${failedR1 ? "sì" : "no"})`, r.secs];
  },

  async d() {
    const max = 180;
    const r = await debate("d", ["ok-a", "ratelimit"], 1, "ok-b", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, bad, r.secs];
    const errs = errMsgs(r.state, "ratelimit");
    if (errs.length) return [false, `errori definitivi per ratelimit: ${errs.map((e) => `${e.phase}: ${e.error.slice(0, 80)}`).join("; ")}`, r.secs];
    const missing = ["initial", "critique"].filter((p) => !okMsgs(r.state, "ratelimit", p).length);
    if (missing.length) return [false, `ratelimit senza messaggi in: ${missing.join(", ")}`, r.secs];
    const ms = okMsgs(r.state, "ratelimit", "initial")[0]?.ms;
    return [true, `done, ratelimit riuscito dopo l'attesa (initial ${ms} ms)`, r.secs];
  },

  async e() {
    const max = 240;
    const r = await debate("e", ["ok-a", "ok-b"], 1, "hang", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, `${bad} dopo ${r.secs.toFixed(0)} s`, r.secs];
    const v = verdictRow(r.state);
    if (!v || v.model_id === "judge:hang") return [false, `verdetto non da un giudice di riserva (${v?.model_id})`, r.secs];
    const tried = (r.state.messages ?? []).filter((m) => m.phase === "verdict" && m.error).map((m) => m.model_id).join(", ");
    return [true, `verdetto da ${v.model_id} in ${r.secs.toFixed(0)} s (falliti: ${tried || "nessuno"})`, r.secs];
  },

  async f() {
    const max = 60;
    const r = await debate("f", ["ok-a", "html"], 0, "ok-a", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, bad, r.secs];
    const t = okMsgs(r.state, "html", "initial")[0]?.content ?? "";
    const need = ["<script>alert(1)</script>", "<img src=x onerror=alert(1)>", "[x](javascript:alert(1))"];
    const lost = need.filter((s) => !t.includes(s));
    if (lost.length) return [false, `il motore ha alterato il testo: mancano ${lost.join(" | ")}`, r.secs];
    return [true, "done, tag salvati intatti (escape lasciato all'interfaccia; md() non testata)", r.secs];
  },

  async g() {
    const max = 180;
    const r = await debate("g", ["ok-a", "empty", "crash500", "gone"], 1, "ok-a", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, bad, r.secs];
    if (!okMsgs(r.state, "ok-a", "initial").length) return [false, "ok-a senza risposta iniziale", r.secs];
    const problems = [];
    for (const m of ["empty", "crash500", "gone"]) {
      if (!errMsgs(r.state, m).length) problems.push(`${m}: nessun errore registrato`);
      if (okMsgs(r.state, m).length) problems.push(`${m}: ha messaggi validi`);
    }
    if (problems.length) return [false, problems.join("; "), r.secs];
    const notes = ["empty", "crash500", "gone"].map((m) => `${m}=${errMsgs(r.state, m)[0].error.slice(0, 40)}`).join(" | ");
    return [true, `done con ok-a; errori: ${notes}`, r.secs];
  },

  async h() {
    const max = 120;
    const r = await debate("h", ["ok-a", "huge"], 1, "ok-b", max * 1000);
    const bad = expectDone(r, max);
    const alive = engine.exitCode === null;
    const m = await api("GET", "/api/models").catch((e) => ({ status: String(e.message) }));
    if (!alive || m.status !== 200) return [false, `motore non raggiungibile dopo huge (vivo: ${alive}, /api/models: ${m.status})`, r.secs];
    if (bad) return [false, bad, r.secs];
    const len = okMsgs(r.state, "huge", "initial")[0]?.content?.length ?? 0;
    return [true, `done, motore raggiungibile, testo huge salvato ${len} caratteri`, r.secs];
  },

  async i() {
    const started = Date.now();
    let id;
    const p = debate("i", ["ok-a", "slow"], 3, "ok-b", 40_000, { onStart: (x) => (id = x) });
    await new Promise((res) => setTimeout(res, 3000));
    const c = await api("POST", `/api/debates/${id}/cancel`, { body: {} });
    if (c.status !== 200) return [false, `cancel → ${c.status}`, (Date.now() - started) / 1000];
    const tCancel = Date.now();
    const r = await p;
    const after = (Date.now() - tCancel) / 1000;
    if (r.state?.status !== "cancelled") return [false, `stato "${r.state?.status}" dopo l'annullamento`, r.secs];
    if (after > 30) return [false, `annullato ma dopo ${after.toFixed(1)} s (> 30 s)`, r.secs];
    return [true, `cancelled ${after.toFixed(1)} s dopo la richiesta`, r.secs];
  },

  async j() {
    const started = Date.now();
    const base = { question: QUESTION("j"), models: ["ok-a", "ok-b"], rounds: 1, judge: "ok-a", claudeModel: "sonnet" };
    const cases = [
      ["question vuota", { body: { ...base, question: "   " } }, 400],
      ["1 solo modello", { body: { ...base, models: ["ok-a"] } }, 400],
      ["rounds 9", { body: { ...base, rounds: 9 } }, 400],
      ["judge inesistente", { body: { ...base, judge: "nessuno" } }, 400],
      ["Content-Type text/plain", { body: JSON.stringify(base), raw: true, headers: { "Content-Type": "text/plain" } }, 415],
      ["Host evil.com", { body: base, headers: { Host: "evil.com" } }, 403],
      ["JSON rovinato", { body: "{question:", raw: true, headers: { "Content-Type": "application/json" } }, 400],
      ["models non array", { body: { ...base, models: "ok-a" } }, 400],
      ["rounds stringa", { body: { ...base, rounds: "2" } }, 400],
      ["modello duplicato (resta 1 solo)", { body: { ...base, models: ["ok-a", "ok-a"] } }, 400],
      ["11 partecipanti (max 10)", { body: { ...base, models: ["ok-a", "ok-b", "hang", "slow", "ratelimit", "quota", "crash500", "empty", "huge", "html", "flaky-critique"] } }, 400],
      ["domanda di 150.000 caratteri", { body: { ...base, question: "x".repeat(150_000) } }, 400],
      ["senza token", { body: base, headers: { Authorization: "" } }, 401],
      ["token sbagliato", { body: base, headers: { Authorization: `Bearer ${"0".repeat(64)}` } }, 401],
      ["token come cookie/query", { body: base, headers: { Authorization: "", Cookie: `token=${TOKEN}` } }, 401],
    ];
    const wrong = [];
    for (const [name, opts, want] of cases) {
      const r = await api("POST", "/api/debates", opts).catch((e) => ({ status: `errore ${e.message}` }));
      // Per gli ultimi casi (non richiesti) basta un 4xx: nessun dibattito avviato, nessun 500.
      const lenient = ["JSON rovinato", "models non array", "rounds stringa", "domanda di 150.000 caratteri"].includes(name);
      const ok = lenient ? typeof r.status === "number" && r.status >= 400 && r.status < 500 : r.status === want;
      if (!ok) wrong.push(`${name}: atteso ${lenient ? "4xx" : want}, avuto ${r.status}`);
    }
    const secs = (Date.now() - started) / 1000;
    if (wrong.length) return [false, wrong.join("; "), secs];
    return [true, `${cases.length} richieste non valide respinte con il codice giusto`, secs];
  },

  async l() {
    // Extra: quota esaurita (nessuna attesa inutile) e risposta troncata per lunghezza.
    const max = 120;
    const r = await debate("l", ["ok-a", "quota", "length"], 1, "ok-a", max * 1000);
    const bad = expectDone(r, max);
    if (bad) return [false, bad, r.secs];
    const problems = [];
    if (!errMsgs(r.state, "quota").length) problems.push("quota: nessun errore registrato");
    const len = okMsgs(r.state, "length", "initial")[0]?.content ?? "";
    if (!/troncat/i.test(len)) problems.push("length: manca l'avviso di troncamento");
    const stats = await api("GET", "/stats", { port: mockPort });
    const qcalls = stats.body?.calls?.quota ?? 0;
    if (qcalls > 2) problems.push(`quota chiamato ${qcalls} volte (riprova inutile su quota esaurita)`);
    if (problems.length) return [false, problems.join("; "), r.secs];
    return [true, `done, quota escluso subito (${qcalls} chiamate), length segnalato come troncato`, r.secs];
  },
};

SCENARIOS.m = async function m() {
  const max = 150;
  const r = await debate("m", ["ok-a", "voce"], 0, "ok-a", max * 1000);
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const msg = r.state.messages.find((x) => x.model_id === "voce" && x.phase === "initial");
  if (!msg?.content) return [false, `la voce non ha risposto (errore: ${msg?.error?.slice(0, 80) ?? "nessun messaggio"})`, r.secs];
  if (msg.model_used !== "ok-b") return [false, `ha risposto ${msg.model_used}, atteso ok-b (riserva)`, r.secs];
  return [true, `done, risposta della riserva ok-b${msg.replaced ? ` al posto di ${msg.replaced}` : ""} in ${(msg.ms / 1000).toFixed(0)} s`, r.secs];
};

// La voce resta sulla riserva: dopo il primo timeout il modello bloccato non viene più chiamato.
SCENARIOS.n = async function n() {
  const max = 200;
  const r = await debate("n", ["ok-a", "voce"], 2, "ok-a", max * 1000);
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const msgs = r.state.messages.filter((x) => x.model_id === "voce" && x.content);
  if (msgs.length < 3) return [false, `la voce ha risposto in ${msgs.length} fasi su 3`, r.secs];
  // Dopo la prima fase la voce deve usare subito la riserva: niente nuove attese da 35 s.
  const later = msgs.filter((x) => x.phase !== "initial");
  const slow = later.filter((x) => (x.ms ?? 0) > 10_000 || x.model_used !== "ok-b");
  if (slow.length) return [false, `nei round successivi la voce ha riatteso o cambiato modello: ${slow.map((x) => `${x.phase} ${x.model_used} ${Math.round(x.ms / 1000)} s`).join(", ")}`, r.secs];
  return [true, `done in ${r.secs.toFixed(0)} s, dopo il primo timeout la voce resta su ok-b (round successivi ${later.map((x) => Math.round(x.ms) + " ms").join(", ")})`, r.secs];
};

// Limite di token in uscita (Qwen su Groq): l'app abbassa max_tokens e riprova subito.
SCENARIOS.o = async function o() {
  const max = 60;
  const r = await debate("o", ["ok-a", "otpm"], 1, "ok-a", max * 1000);
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const ok = r.state.messages.filter((x) => x.model_id === "otpm" && x.content).length;
  if (ok < 2) return [false, `otpm ha risposto in ${ok} fasi su 2 (errori: ${errMsgs(r.state, "otpm").map((m) => m.error.slice(0, 60)).join("; ")})`, r.secs];
  return [true, `done, otpm ha risposto in tutte le fasi abbassando max_tokens`, r.secs];
};

// Chiavi mai visibili: il provider ripete la chiave nell'errore, ma né cronologia, né eventi,
// né log del motore devono contenerla (né il token dell'API).
SCENARIOS.p = async function p() {
  const max = 60;
  const r = await debate("p", ["ok-a", "ok-b", "leaky", "badkey"], 0, "ok-a", max * 1000);
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const err = errMsgs(r.state, "leaky")[0]?.error ?? "";
  if (!err) return [false, "leaky senza errore registrato", r.secs];
  if (!errMsgs(r.state, "badkey").length) return [false, "badkey senza errore registrato", r.secs];
  const where = { cronologia: JSON.stringify(r.state), eventi: JSON.stringify(r.events), log: engine.log.join("\n") };
  const leaks = Object.entries(where).flatMap(([k, t]) =>
    [[CHAOS_KEY, "chiave"], [BAD_KEY_TAIL, "chiave rovinata"], [FAKE_GOOGLE_KEY, "AIza"], [TOKEN, "token"]].filter(([v]) => t.includes(v)).map(([, n]) => `${n} in ${k}`));
  if (leaks.length) return [false, `segreti visibili: ${leaks.join(", ")}`, r.secs];
  if (!err.includes("[chiave nascosta]")) return [false, `errore senza maschera: ${err.slice(0, 80)}`, r.secs];
  return [true, `done, errore mascherato: "${err.slice(0, 70)}…"`, r.secs];
};

// File dei dati leggibili solo dall'utente (cartelle 0700, file 0600).
SCENARIOS.q = async function q() {
  const started = Date.now();
  const open = [];
  const walk = async (dir) => {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      const f = join(dir, e.name);
      if (f.endsWith("models.chaos.json")) continue; // scritto dalla suite, non dal motore
      const mode = (await stat(f)).mode & 0o777;
      if (mode & 0o077) open.push(`${f.slice(dataDir.length + 1)} ${mode.toString(8)}`);
      if (e.isDirectory()) await walk(f);
    }
  };
  await walk(dataDir);
  const secs = (Date.now() - started) / 1000;
  if (open.length) return [false, `leggibili da altri: ${open.slice(0, 5).join(", ")}`, secs];
  return [true, "database, WAL e file del motore solo per l'utente", secs];
};

// Corpo con accenti spezzato a metà carattere tra due pacchetti; corpi "null" → 400, mai 500.
SCENARIOS.r = async function r() {
  const started = Date.now();
  const question = `[scenario:r] Perché l'università è così? ${"àèìòù€ ".repeat(40)}`;
  const body = Buffer.from(JSON.stringify({ question, models: ["ok-a", "ok-b"], rounds: 0, judge: "ok-a", claudeModel: "sonnet" }));
  const cut = body.indexOf(Buffer.from("€")) + 1; // dentro i 3 byte di "€"
  const text = await new Promise((resolve, reject) => {
    const sock = connect(enginePort, "127.0.0.1", () => {
      sock.write(`POST /api/debates HTTP/1.1\r\nHost: 127.0.0.1:${enginePort}\r\nAuthorization: Bearer ${TOKEN}\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n`);
      sock.write(body.subarray(0, cut));
      setTimeout(() => sock.write(body.subarray(cut)), 150);
    });
    let s = "";
    sock.setEncoding("utf8");
    sock.on("data", (c) => (s += c));
    sock.on("end", () => resolve(s));
    sock.on("error", reject);
  });
  const secs = () => (Date.now() - started) / 1000;
  const id = Number(text.match(/"id":(\d+)/)?.[1]);
  if (!id) return [false, `dibattito non creato: ${text.slice(0, 80)}`, secs()];
  const saved = (await api("GET", `/api/debates/${id}`)).body?.question;
  if (saved !== question.trim()) return [false, `domanda alterata (${[...(saved ?? "")].filter((c) => c === "\ufffd").length} caratteri rovinati)`, secs()];
  const wrong = [];
  for (const [method, path] of [["POST", "/api/probe"], ["PUT", "/api/selection"], ["POST", "/api/debates"]]) {
    for (const raw of ["null", "[]", '"x"']) {
      const x = await api(method, path, { body: raw, raw: true, headers: { "Content-Type": "application/json" } });
      if (x.status !== 400) wrong.push(`${method} ${path} ${raw} → ${x.status}`);
    }
  }
  if (wrong.length) return [false, wrong.join("; "), secs()];
  return [true, "domanda intatta, 9 corpi non-oggetto respinti con 400", secs()];
};

// Eliminare un dibattito in corso: sparisce, non restano righe orfane, il motore resta vivo.
SCENARIOS.s = async function s() {
  const started = Date.now();
  const c = await api("POST", "/api/debates", { body: { question: QUESTION("s"), models: ["ok-a", "slow"], rounds: 1, judge: "ok-a", claudeModel: "sonnet" } });
  const id = c.body?.id;
  await new Promise((res) => setTimeout(res, 1000));
  const d = await api("DELETE", `/api/debates/${id}`);
  await new Promise((res) => setTimeout(res, 1500));
  const g = await api("GET", `/api/debates/${id}`);
  const db = new DatabaseSync(join(dataDir, "data", "council.db"), { readOnly: true });
  const orphans = db.prepare("SELECT count(*) AS n FROM messages WHERE debate_id = ?").get(id).n;
  db.close();
  const secs = (Date.now() - started) / 1000;
  if (d.status !== 200 || g.status !== 404) return [false, `DELETE ${d.status}, poi GET ${g.status}`, secs];
  if (orphans) return [false, `${orphans} messaggi orfani dopo l'eliminazione`, secs];
  if (engine.exitCode !== null) return [false, "motore terminato", secs];
  return [true, "eliminato a metà: GET 404, nessun messaggio orfano", secs];
};

// Chi si scollega e si ricollega a metà riceve di nuovo tutti gli eventi dall'inizio.
SCENARIOS.t = async function t() {
  const started = Date.now();
  const c = await api("POST", "/api/debates", { body: { question: QUESTION("t"), models: ["ok-a", "slow"], rounds: 0, judge: "ok-a", claudeModel: "sonnet" } });
  const id = c.body?.id;
  const first = await followEvents(id, 2000);
  const second = await followEvents(id, 60_000);
  const secs = (Date.now() - started) / 1000;
  if (!first.timedOut) return [false, "il dibattito è finito prima dello scollegamento", secs];
  if (second.events[0]?.type !== "start") return [false, `il replay non riparte da start (${second.events[0]?.type})`, secs];
  if (second.events.length < first.events.length) return [false, "replay più corto degli eventi già visti", secs];
  if (doneEvent(second.events)?.status !== "done") return [false, `nessun done dopo il ricollegamento`, secs];
  return [true, `ricollegato: ${second.events.length} eventi da start a done`, secs];
};

// Riga del titolo: solo in testa e sulla sua riga, senza mangiare il verdetto.
SCENARIOS.u = async function u() {
  const { splitTitle } = await import("../../src/debate/prompts.ts");
  const cases = [
    ["TITOLO: Treno o aereo\n\n## Verdetto\nTesto", "Treno o aereo", "## Verdetto\nTesto"],
    ["**TITLE:** Train or plane\nText", "Train or plane", "Text"],
    ["**TITOLO**: Grassetto fuori\nTesto", "Grassetto fuori", "Testo"],
    ["## TITOLO: Con cancelletto\nTesto", "Con cancelletto", "Testo"],
    ["TITOLO:\n## Risposta\nTesto", null, "## Risposta\nTesto"],
    ["Nessun titolo qui.\nTesto", null, "Nessun titolo qui.\nTesto"],
    [`${"x".repeat(300)}\nTITOLO: Tardi\nTesto`, null, `${"x".repeat(300)}\nTITOLO: Tardi\nTesto`],
  ];
  const wrong = cases.filter(([input, title, verdict]) => {
    const r = splitTitle(input);
    return r.title !== title || r.verdict !== verdict;
  }).map(([input]) => JSON.stringify(input.slice(0, 30)));
  if (wrong.length) return [false, `casi sbagliati: ${wrong.join(", ")}`, 0];
  return [true, `${cases.length} casi di titolo corretti`, 0];
};

// Giudice che scrive solo il titolo: il verdetto vuoto non si accetta, decide la riserva.
SCENARIOS.v = async function v() {
  const max = 60;
  const r = await debate("v", ["ok-a", "ok-b"], 0, "titleonly", max * 1000);
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const row = verdictRow(r.state);
  if (!row || row.model_id === "judge:titleonly") return [false, `verdetto accettato da ${row?.model_id}`, r.secs];
  const failed = (r.state.messages ?? []).find((m) => m.model_id === "judge:titleonly" && m.error);
  if (!failed) return [false, "nessun errore registrato per il giudice a verdetto vuoto", r.secs];
  return [true, `verdetto vuoto scartato (${failed.error}), deciso da ${row.model_id}`, r.secs];
};

// ---------- chiavi dall'app (hello sullo stdin) ----------

/** Ambiente pulito per un motore in più: nessuna chiave delle prove ereditata dal runner. */
function cleanEnv(extra) {
  const env = { ...process.env, PORT: "0", COUNCIL_PARENT: "app", ...extra };
  for (const k of Object.keys(env)) if (/_(API_)?KEY$|_TOKEN$/.test(k) || k === "NODE_OPTIONS") delete env[k];
  return env;
}

/** Avvia un motore separato (dati e config propri) con la riga di hello data. */
async function startExtraEngine(cfg, hello, { dotenv, env: extra } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "council-chaos-keys-"));
  extraDirs.push(dir);
  const cfgPath = join(dir, "models.json");
  await writeFile(cfgPath, JSON.stringify(cfg));
  if (dotenv) await writeFile(join(dir, ".env"), dotenv);
  const e = await startProcess(process.execPath, ["--disable-warning=ExperimentalWarning", "src/server.ts"],
    cleanEnv({ COUNCIL_DATA: dir, COUNCIL_MODELS: cfgPath, ...extra }), "COUNCIL_PORT", hello);
  extraProcs.push(e.proc);
  e.proc.removeAllListeners("exit");
  e.proc.on("exit", (code) => { e.proc.exited = code ?? "signal"; });
  return { ...e, dir };
}

const authed = (tok) => ({ Authorization: `Bearer ${tok}` });

// Chiavi passate dall'app sullo stdin: arrivano al provider (con precedenza su .env), la Claude
// CLI non le eredita, e se il provider le ripete nell'errore non compaiono in log né cronologia.
SCENARIOS.w = async function w() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const tok = randomBytes(32).toString("hex");
  const APP_KEY = "app-keychain-key-" + randomBytes(12).toString("hex");
  const DOTENV_KEY = "dotenv-key-should-lose-0123456789";
  // Finta Claude CLI: risponde con i nomi delle variabili sensibili che ha ereditato.
  const bin = await mkdtemp(join(tmpdir(), "council-chaos-bin-"));
  extraDirs.push(bin);
  await writeFile(join(bin, "claude"), `#!${process.execPath}\nprocess.stdin.resume();process.stdin.on("end",()=>{const n=Object.keys(process.env).filter(k=>/_KEY$|_TOKEN$|^COUNCIL_/.test(k));process.stdout.write(JSON.stringify({result:"ENV["+n.join(",")+"]"}))});\n`);
  await chmod(join(bin, "claude"), 0o755);
  const cfg = {
    providers: { app: { name: "Dall'app", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "APP_PROV_API_KEY" } },
    judge: { id: "j", label: "Giudice", kind: "openai", provider: "app", model: "whoami" },
    models: [
      { id: "whoami", label: "Whoami", kind: "openai", provider: "app", model: "whoami", family: "whoami", default: false },
      { id: "leaky", label: "Leaky", kind: "openai", provider: "app", model: "leaky", family: "leaky", default: false },
      { id: "fakeclaude", label: "Finta Claude", kind: "claude-cli", model: "sonnet", default: false },
    ],
  };
  const e = await startExtraEngine(cfg, JSON.stringify({ token: tok, keys: { APP_PROV_API_KEY: APP_KEY } }),
    { dotenv: `APP_PROV_API_KEY=${DOTENV_KEY}\n`, env: { PATH: `${bin}:${process.env.PATH}` } });
  const c = await api("POST", "/api/debates", { port: e.port, headers: authed(tok),
    body: { question: QUESTION("w"), models: ["whoami", "leaky", "fakeclaude"], rounds: 0, judge: "whoami", claudeModel: "sonnet" } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  let state;
  for (let i = 0; i < 100; i++) {
    state = (await api("GET", `/api/debates/${c.body.id}`, { port: e.port, headers: authed(tok) })).body;
    if (state?.status && state.status !== "running") break;
    await new Promise((res) => setTimeout(res, 300));
  }
  if (state?.status !== "done") return [false, `stato "${state?.status}"`, secs()];
  const got = (await api("GET", "/stats", { port: mockPort })).body?.auths?.whoami;
  if (got !== `Bearer ${APP_KEY}`) return [false, `il provider ha ricevuto ${got?.includes(DOTENV_KEY) ? "la chiave di .env" : "un'altra intestazione"}`, secs()];
  const claudeOut = okMsgs(state, "fakeclaude")[0]?.content ?? "";
  if (!claudeOut.startsWith("ENV[")) return [false, `finta Claude senza risposta: ${claudeOut.slice(0, 60)}`, secs()];
  if (/APP_PROV_API_KEY|COUNCIL_/.test(claudeOut)) return [false, `la Claude CLI eredita: ${claudeOut.slice(0, 80)}`, secs()];
  const err = errMsgs(state, "leaky")[0]?.error ?? "";
  if (!err.includes("[chiave nascosta]")) return [false, `errore di leaky senza maschera`, secs()];
  const where = { cronologia: JSON.stringify(state), log: e.proc.log.join("\n") };
  const leaks = Object.entries(where).flatMap(([k, t]) =>
    [[APP_KEY, "chiave dall'app"], [DOTENV_KEY, "chiave di .env"], [tok, "token"]].filter(([v]) => t.includes(v)).map(([, n]) => `${n} in ${k}`));
  if (leaks.length) return [false, `segreti visibili: ${leaks.join(", ")}`, secs()];
  return [true, `Bearer dall'app (non .env), Claude CLI senza chiavi, errore mascherato`, secs()];
};

// Hello ostili: il motore parte comunque e nessun campo non valido diventa una variabile.
SCENARIOS.x = async function x() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const names = ["HOSTILE_API_KEY", "HOSTILE2_API_KEY", "HOSTILE3_API_KEY", "HOSTILE4_API_KEY", "HOSTILE5_API_KEY",
    "HOSTILE6_API_KEY", "HOSTILE7_TOKEN", "NODE_OPTIONS", "COUNCIL_TEST_TOKEN", "VALID_API_KEY"];
  const providers = Object.fromEntries(names.map((n) => [n.toLowerCase().replace(/_/g, "-"), { baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: n }]));
  const first = Object.keys(providers)[0];
  const cfg = {
    providers,
    judge: { id: "j", label: "Giudice", kind: "openai", provider: first, model: "ok-a" },
    models: [{ id: "m", label: "M", kind: "openai", provider: first, model: "ok-a", family: "m", default: false }],
  };
  const secretValues = ["valid-looking-key-123", "lowercase-key-1234", "trailing-space-name-123", "no-suffix-12345",
    "--require=/nonexistent/x.js", "test-token-that-should-not-apply-0123456789", "break-123456", "y".repeat(5000)];
  const mixed = {
    "__proto__": { HOSTILE_API_KEY: secretValues[0] },
    "hostile_api_key": secretValues[1],
    "HOSTILE_API_KEY ": secretValues[2],
    "HOSTILE_API": secretValues[3],
    "NODE_OPTIONS": secretValues[4],
    "COUNCIL_TEST_TOKEN": secretValues[5],
    "HOSTILE2_API_KEY": `line\n${secretValues[6]}`,
    "HOSTILE3_API_KEY": secretValues[7],
    "HOSTILE4_API_KEY": 12345678901,
    "HOSTILE5_API_KEY": "",
    "HOSTILE6_API_KEY": "short",
    "HOSTILE7_TOKEN": { nested: "object-value-12345" },
    "VALID_API_KEY": "valid-key-0123456789",
  };
  const hellos = [["stringa", "HOSTILE_API_KEY=abc12345678"], ["array", ["HOSTILE_API_KEY", "abc12345678"]], ["null", null], ["numero", 42], ["misto", mixed]];
  const tok = randomBytes(32).toString("hex");
  // JSON.stringify ignora "__proto__" scritto in un letterale (è il prototipo): lo si inserisce a mano.
  const helloText = (keys) => JSON.stringify({ token: tok, keys }).replace('"keys":{', `"keys":{"__proto__":${JSON.stringify(mixed.__proto__)},`);
  const wrong = [];
  await Promise.all(hellos.map(async ([label, keys]) => {
    let e;
    try {
      e = await startExtraEngine(cfg, label === "misto" ? helloText(keys) : JSON.stringify({ token: tok, keys }));
    } catch (err) { wrong.push(`${label}: motore non partito (${err.message})`); return; }
    const r = await api("GET", "/api/providers", { port: e.port, headers: authed(tok) });
    if (r.status !== 200) { wrong.push(`${label}: /api/providers ${r.status}`); return; }
    const set = r.body.filter((p) => p.hasKey).map((p) => providers[p.id]?.keyEnv ?? p.id);
    const expected = label === "misto" ? ["VALID_API_KEY"] : [];
    if (set.join() !== expected.join()) wrong.push(`${label}: chiavi impostate [${set.join(",")}]`);
    const log = e.proc.log.join("\n");
    const shown = secretValues.filter((v) => log.includes(v.slice(0, 40)));
    if (shown.length) wrong.push(`${label}: ${shown.length} valori nel log`);
    if (e.proc.exited !== undefined) wrong.push(`${label}: motore terminato`);
  }));
  if (wrong.length) return [false, wrong.join("; "), secs()];
  return [true, `${hellos.length} hello ostili: motore vivo, solo VALID_API_KEY impostata, nessun valore nel log`, secs()];
};

// Motore ucciso (SIGKILL, come un crash) con un dibattito "running": riavviato sulla stessa cartella
// dati, il dibattito risulta "interrupted" sia nel dettaglio sia nella lista, e non è più live.
SCENARIOS.y = async function y() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const dir = await mkdtemp(join(tmpdir(), "council-chaos-restart-"));
  extraDirs.push(dir);
  const cfgPath = join(dir, "models.json");
  await writeFile(cfgPath, JSON.stringify({
    providers: { chaos: { name: "Chaos", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_KEY" } },
    judge: { id: "j", label: "Giudice", kind: "openai", provider: "chaos", model: "ok-a" },
    models: [
      { id: "lento", label: "Lento", kind: "openai", provider: "chaos", model: "slow", family: "lento", default: false },
      { id: "bloccato", label: "Bloccato", kind: "openai", provider: "chaos", model: "hang", family: "bloccato", default: false },
    ],
  }));
  const boot = async () => {
    const tok = randomBytes(32).toString("hex");
    const e = await startProcess(process.execPath, ["--disable-warning=ExperimentalWarning", "src/server.ts"],
      cleanEnv({ COUNCIL_DATA: dir, COUNCIL_MODELS: cfgPath }), "COUNCIL_PORT", JSON.stringify({ token: tok, keys: { CHAOS_KEY } }));
    extraProcs.push(e.proc);
    e.proc.removeAllListeners("exit");
    e.proc.on("exit", (code) => { e.proc.exited = code ?? "signal"; });
    return { ...e, h: authed(tok) };
  };
  const e1 = await boot();
  const c = await api("POST", "/api/debates", { port: e1.port, headers: e1.h,
    body: { question: QUESTION("y"), models: ["lento", "bloccato"], rounds: 1, judge: "lento", claudeModel: "sonnet" } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  const id = c.body.id;
  // Attende che il dibattito sia davvero in corso (salvato come running) prima del crash.
  await new Promise((res) => setTimeout(res, 1500));
  const before = await api("GET", `/api/debates/${id}`, { port: e1.port, headers: e1.h });
  if (before.body?.status !== "running") return [false, `prima del crash stato "${before.body?.status}"`, secs()];
  const gone = new Promise((res) => e1.proc.once("exit", res));
  e1.proc.kill("SIGKILL");
  await gone;
  const e2 = await boot();
  const d = await api("GET", `/api/debates/${id}`, { port: e2.port, headers: e2.h });
  if (d.status !== 200) return [false, `GET dopo il riavvio → ${d.status}`, secs()];
  if (d.body.status !== "interrupted") return [false, `stato dopo il riavvio "${d.body.status}"`, secs()];
  if (d.body.live) return [false, "dibattito interrotto ancora segnato live", secs()];
  const l = await api("GET", "/api/debates", { port: e2.port, headers: e2.h });
  const row = Array.isArray(l.body) ? l.body.find((x) => x.id === id) : null;
  if (!row) return [false, `dibattito assente dalla lista (${l.status})`, secs()];
  if (row.status !== "interrupted") return [false, `nella lista stato "${row.status}"`, secs()];
  const ev = await api("GET", `/api/debates/${id}/events`, { port: e2.port, headers: e2.h });
  if (ev.status !== 404) return [false, `flusso eventi di un dibattito interrotto → ${ev.status}`, secs()];
  e2.proc.kill("SIGTERM");
  return [true, `dopo SIGKILL e riavvio: interrupted in dettaglio e lista, non live, eventi 404`, secs()];
};

// Giudice lento (mock "slow", 20 s): il flusso SSE non deve restare muto più di HEARTBEAT_MAX_S
// mentre il giudice lavora. Si contano anche i commenti SSE (righe ":"), che fanno da heartbeat.
// I tempi del motore non sono configurabili: lo scenario dura ~25 s.
const HEARTBEAT_MAX_S = 16;
SCENARIOS.z = async function z() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const c = await api("POST", "/api/debates", { body: { question: QUESTION("z"), models: ["ok-a", "ok-b"], rounds: 0, judge: "slow", claudeModel: "sonnet" } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  const id = c.body.id;
  const res = await new Promise((resolve) => {
    let last = Date.now(), maxGap = 0, comments = 0, judgeAt = null, done = false, buf = "";
    const finish = (timedOut) => {
      clearTimeout(timer);
      req.destroy();
      resolve({ maxGap, comments, judgeAt, done, timedOut });
    };
    const timer = setTimeout(() => finish(true), 60_000);
    const req = request({ host: "127.0.0.1", port: enginePort, path: `/api/debates/${id}/events`, headers: { Host: `127.0.0.1:${enginePort}`, Authorization: `Bearer ${TOKEN}` } }, (r) => {
      if (r.statusCode !== 200) { r.resume(); return finish(false); }
      r.setEncoding("utf8");
      r.on("data", (chunk) => {
        const now = Date.now();
        // Il silenzio conta solo durante il giudice: prima i modelli ok rispondono subito.
        if (judgeAt !== null) maxGap = Math.max(maxGap, (now - last) / 1000);
        last = now;
        buf += chunk;
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const block = buf.slice(0, i);
          buf = buf.slice(i + 2);
          for (const line of block.split("\n")) {
            if (line.startsWith(":")) comments++;
            if (!line.startsWith("data: ")) continue;
            try {
              const e = JSON.parse(line.slice(6));
              if (e.type === "phase" && e.phase === "verdict" && judgeAt === null) judgeAt = now;
              if (e.type === "done") { done = true; return finish(false); }
            } catch { /* riga non JSON */ }
          }
        }
      });
      r.on("end", () => finish(false));
    });
    req.on("error", () => finish(false));
    req.end();
  });
  if (res.timedOut || !res.done) return [false, `nessun evento done (${res.timedOut ? "scaduto" : "flusso chiuso"})`, secs()];
  if (res.judgeAt === null) return [false, "nessun evento phase del giudice nel flusso", secs()];
  if (res.maxGap > HEARTBEAT_MAX_S)
    return [false, `DIFETTO: flusso muto ${res.maxGap.toFixed(1)} s durante il giudice (${res.comments} heartbeat; il motore non manda commenti SSE)`, secs()];
  return [true, `silenzio massimo ${res.maxGap.toFixed(1)} s, ${res.comments} heartbeat`, secs()];
};

// ---------- ricerca sul web e allegati ----------

const RESEARCH_TIMEOUT_S = 6;
const promptsOf = async (tag) => (await api("GET", `/prompts/${tag}`, { port: mockPort })).body ?? [];
const phaseEvent = (events, phase) => events.findIndex((e) => e.type === "phase" && e.phase === phase);

// Ricerca via Groq finto: fase research prima di initial, dossier ripulito dai rimandi 【…】 e con le
// pagine consultate, nel prompt iniziale e del giudice ma non nei round intermedi.
SCENARIOS.aa = async function aa() {
  const max = 90;
  const ws = (await api("GET", "/api/models")).body?.webSearch;
  if (!ws?.available || ws.via !== "GPT-OSS (Groq)") return [false, `/api/models webSearch = ${JSON.stringify(ws)}`, 0];
  const r = await debate("web-ok", ["ok-a", "ok-b"], 1, "ok-a", max * 1000, { extra: { webSearch: true } });
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const iR = phaseEvent(r.events, "research"), iI = phaseEvent(r.events, "initial");
  if (iR < 0 || iI < 0 || iR > iI) return [false, `ordine delle fasi sbagliato (research ${iR}, initial ${iI})`, r.secs];
  const ev = r.events.find((e) => e.type === "message" && e.phase === "research");
  if (ev?.modelId !== "research:gptoss" || !/gpt-oss/.test(ev.model ?? "")) return [false, `evento research: ${JSON.stringify(ev)?.slice(0, 100)}`, r.secs];
  const row = okMsgs(r.state, "research:gptoss", "research")[0];
  if (!row) return [false, "dossier non salvato nella cronologia", r.secs];
  if (row.content.includes("【")) return [false, "rimandi 【…】 non ripuliti", r.secs];
  if (!row.content.includes(DOSSIER_URL) || !row.content.includes("https://example.org/altra")) return [false, "fonti mancanti nel dossier", r.secs];
  if (r.state.options?.webSearch !== true) return [false, `options.webSearch = ${r.state.options?.webSearch}`, r.secs];
  const pr = await promptsOf("web-ok");
  const search = pr.filter((p) => p.phase === "research");
  if (search.length !== 1) return [false, `${search.length} richieste di ricerca (attesa 1)`, r.secs];
  if (search[0].reasoning_effort !== "low" || !/gpt-oss-(120b|20b)$/.test(search[0].model)) return [false, `ricerca con ${search[0].model}, reasoning ${search[0].reasoning_effort}`, r.secs];
  const wrong = [];
  for (const p of pr.filter((x) => x.phase !== "research")) {
    const has = p.user.includes("RISULTATI DELLA RICERCA SUL WEB") && p.user.includes(DOSSIER_MARK);
    const want = p.phase === "initial" || p.phase === "verdict";
    if (has !== want) wrong.push(`${p.phase}/${p.model}: dossier ${has ? "presente" : "assente"}`);
  }
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), r.secs];
  return [true, `research prima di initial, dossier ripulito con fonti, nei prompt iniziali e del giudice (${pr.length} prompt)`, r.secs];
};

// Nessuno può cercare (niente Claude, niente GPT-OSS su Groq): nota e il dibattito prosegue.
SCENARIOS.ab = async function ab() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const tok = randomBytes(32).toString("hex");
  const prov = { baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_KEY" };
  const cfg = {
    providers: { chaos: { name: "Chaos", ...prov } },
    judge: { id: "j", label: "Giudice", kind: "openai", provider: "chaos", model: "ok-a" },
    models: [
      { id: "ok-a", label: "A", kind: "openai", provider: "chaos", model: "ok-a", family: "ok-a", default: false },
      { id: "ok-b", label: "B", kind: "openai", provider: "chaos", model: "ok-b", family: "ok-b", default: false },
      // GPT-OSS ma non su Groq: non conta come ricercatore.
      { id: "gptoss", label: "GPT-OSS altrove", kind: "openai", provider: "chaos", model: "openai/gpt-oss-120b", family: "gpt-oss", default: false },
    ],
  };
  const e = await startExtraEngine(cfg, JSON.stringify({ token: tok, keys: { CHAOS_KEY } }));
  const ws = (await api("GET", "/api/models", { port: e.port, headers: authed(tok) })).body?.webSearch;
  if (!ws || ws.available !== false || ws.via !== null) return [false, `/api/models webSearch = ${JSON.stringify(ws)}`, secs()];
  const c = await api("POST", "/api/debates", { port: e.port, headers: authed(tok),
    body: { question: QUESTION("web-none"), models: ["ok-a", "ok-b"], rounds: 0, judge: "ok-a", claudeModel: "sonnet", webSearch: true } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  let state;
  for (let i = 0; i < 100; i++) {
    state = (await api("GET", `/api/debates/${c.body.id}`, { port: e.port, headers: authed(tok) })).body;
    if (state?.status && state.status !== "running") break;
    await new Promise((res) => setTimeout(res, 300));
  }
  e.proc.kill("SIGTERM");
  if (state?.status !== "done") return [false, `stato "${state?.status}"`, secs()];
  const note = state.messages.find((m) => m.model_id === "_note" && m.phase === "research");
  if (!note) return [false, "nessuna nota sulla ricerca non disponibile", secs()];
  if (state.messages.some((m) => m.phase === "research" && m.model_id !== "_note")) return [false, "messaggi di ricerca senza ricercatore", secs()];
  return [true, `done, nota: "${note.content.slice(0, 50)}…"`, secs()];
};

// Ricercatore bloccato: errore non fatale entro il tempo massimo, poi il dibattito prosegue senza dossier.
SCENARIOS.ac = async function ac() {
  const max = 90;
  const r = await debate("web-hang", ["ok-a", "ok-b"], 0, "ok-a", max * 1000, { extra: { webSearch: true } });
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const err = r.events.find((e) => e.type === "error" && e.phase === "research");
  if (err?.modelId !== "research") return [false, `nessun errore di ricerca (${JSON.stringify(err)?.slice(0, 80)})`, r.secs];
  if (!errMsgs(r.state, "research").length) return [false, "errore di ricerca non salvato", r.secs];
  if (r.secs > RESEARCH_TIMEOUT_S + 15) return [false, `troppo lento: ${r.secs.toFixed(0)} s`, r.secs];
  const pr = await promptsOf("web-hang");
  if (pr.some((p) => p.user.includes("RISULTATI DELLA RICERCA SUL WEB"))) return [false, "blocco di ricerca nei prompt senza dossier", r.secs];
  return [true, `done in ${r.secs.toFixed(0)} s, errore non fatale: "${err.error.slice(0, 60)}…"`, r.secs];
};

const ATT_LONG = `INIZIO-ALL-1 ${"clausola di prova. ".repeat(300)} FINE-ALL-1`;

// Allegati validi: testo completo nel prompt iniziale e del giudice, estratto nei round intermedi,
// solo metadati nella cronologia, testo completo nel DB; non passano all'approfondimento.
SCENARIOS.ad = async function ad() {
  const max = 120;
  const attachments = [
    { name: "contratto.pdf", kind: "pdf", text: ATT_LONG },
    { name: "note\n## finto titolo", kind: "text", text: "INIZIO-ALL-2 testo breve FINE-ALL-2" },
  ];
  const r = await debate("att-ok", ["ok-a", "ok-b"], 2, "ok-a", max * 1000, { extra: { attachments } });
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const meta = msgs(r.state, "_attachments", "start")[0];
  let list = null;
  try { list = JSON.parse(meta?.content ?? "null"); } catch { /* sotto */ }
  if (!Array.isArray(list) || list.length !== 2 || list[0].chars !== ATT_LONG.length || list[1].kind !== "text") return [false, `metadati _attachments: ${meta?.content?.slice(0, 100)}`, r.secs];
  if (JSON.stringify(r.state).includes("FINE-ALL-1")) return [false, "testo completo degli allegati restituito all'app", r.secs];
  const db = new DatabaseSync(join(dataDir, "data", "council.db"), { readOnly: true });
  const stored = db.prepare("SELECT text FROM attachments WHERE debate_id = ? ORDER BY id").all(r.id).map((x) => x.text);
  db.close();
  if (stored[0] !== ATT_LONG) return [false, `testo nel DB: ${stored.length} righe, primo ${stored[0]?.length} caratteri`, r.secs];
  const pr = await promptsOf("att-ok");
  const wrong = [];
  for (const p of pr) {
    const full = p.user.includes("ALLEGATI:\n### contratto.pdf") && p.user.includes("FINE-ALL-1") && p.user.includes("FINE-ALL-2");
    const excerpt = p.user.includes("solo un estratto") && p.user.includes("INIZIO-ALL-1") && !p.user.includes("FINE-ALL-1");
    if (p.user.includes("\n## finto titolo")) wrong.push(`${p.phase}: nome con a capo non ripulito`);
    if ((p.phase === "initial" || p.phase === "verdict") && !full) wrong.push(`${p.phase}/${p.model}: allegati non completi`);
    if ((p.phase === "critique" || p.phase === "revise") && !excerpt) wrong.push(`${p.phase}/${p.model}: estratto assente o troppo lungo`);
  }
  const phases = new Set(pr.map((p) => p.phase));
  for (const ph of ["initial", "critique", "revise", "verdict"]) if (!phases.has(ph)) wrong.push(`nessun prompt ${ph}`);
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), r.secs];
  // Approfondimento: solo domanda e verdetto della discussione madre.
  const c = await api("POST", "/api/debates", { body: { question: QUESTION("att-child"), models: ["ok-a", "ok-b"], rounds: 0, judge: "ok-a", claudeModel: "sonnet", parentId: r.id } });
  if (c.status !== 201) return [false, `approfondimento → ${c.status}`, r.secs];
  const child = await followEvents(c.body.id, 60_000);
  if (doneEvent(child.events)?.status !== "done") return [false, "approfondimento non concluso", r.secs];
  const cp = await promptsOf("att-child");
  const init = cp.find((p) => p.phase === "initial");
  if (!init?.user.includes("DISCUSSIONE PRECEDENTE")) return [false, `approfondimento senza contesto (${cp.map((p) => p.phase).join(",")}: ${init?.user.slice(0, 80)})`, r.secs];
  if (cp.some((p) => p.user.includes("INIZIO-ALL") || p.user.includes("ALLEGATI"))) return [false, "allegati della madre passati all'approfondimento", r.secs];
  return [true, `allegati completi in initial/verdict, estratto in critique/revise, metadati in cronologia, testo nel DB, non ereditati`, r.secs];
};

// Allegati oltre i limiti o malformati, webSearch non booleano, corpo enorme: 400/413, mai 500.
SCENARIOS.ae = async function ae() {
  const started = Date.now();
  const base = { question: QUESTION("att-bad"), models: ["ok-a", "ok-b"], rounds: 0, judge: "ok-a", claudeModel: "sonnet" };
  const a = (text, extra = {}) => ({ name: "a.txt", kind: "text", text, ...extra });
  const cases = [
    ["attachments non elenco", { attachments: "x" }, 400],
    ["attachments oggetto", { attachments: { name: "a" } }, 400],
    ["6 allegati", { attachments: Array(6).fill(a("x")) }, 400],
    ["allegato null", { attachments: [null] }, 400],
    ["allegato elenco", { attachments: [["a"]] }, 400],
    ["kind sconosciuto", { attachments: [a("x", { kind: "exe" })] }, 400],
    ["kind mancante", { attachments: [{ name: "a", text: "x" }] }, 400],
    ["text numero", { attachments: [a(42)] }, 400],
    ["name mancante", { attachments: [{ kind: "pdf", text: "x" }] }, 400],
    ["nome di 201 caratteri", { attachments: [a("x", { name: "n".repeat(201) })] }, 400],
    ["testo di 40.001 caratteri", { attachments: [a("x".repeat(40_001))] }, 400],
    ["totale 60.002 caratteri", { attachments: [a("x".repeat(30_001)), a("y".repeat(30_001))] }, 400],
    ["webSearch stringa", { webSearch: "yes" }, 400],
    ["webSearch numero", { webSearch: 1 }, 400],
    ["corpo > 400.000 caratteri", { attachments: [a("x".repeat(410_000))] }, 413],
  ];
  const wrong = [];
  for (const [name, extra, want] of cases) {
    const r = await api("POST", "/api/debates", { body: { ...base, ...extra } }).catch((e) => ({ status: `errore ${e.message}` }));
    if (r.status !== want) wrong.push(`${name}: atteso ${want}, avuto ${r.status}`);
  }
  // Nessun dibattito creato dalle richieste respinte.
  const list = (await api("GET", "/api/debates?q=att-bad")).body ?? [];
  if (list.length) wrong.push(`${list.length} dibattiti creati da richieste non valide`);
  const secs = (Date.now() - started) / 1000;
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs];
  return [true, `${cases.length} richieste non valide respinte con il codice giusto, nessun dibattito creato`, secs];
};

// Allegati esattamente al limite (5 × 12.000 = 60.000 caratteri) e un modello con il limite di token
// al minuto di Groq gratis: quel modello esce in modo pulito (una chiamata, nessun ciclo), gli altri proseguono.
SCENARIOS.af = async function af() {
  const max = 90;
  const attachments = Array.from({ length: 5 }, (_, i) => ({ name: `parte-${i + 1}.txt`, kind: "text", text: `P${i}`.padEnd(12_000, "z") }));
  const before = (await api("GET", "/stats", { port: mockPort })).body?.calls?.tpm ?? 0;
  const r = await debate("att-max", ["ok-a", "ok-b", "tpm"], 1, "ok-a", max * 1000, { extra: { attachments } });
  const bad = expectDone(r, max);
  if (bad) return [false, bad, r.secs];
  const calls = ((await api("GET", "/stats", { port: mockPort })).body?.calls?.tpm ?? 0) - before;
  const err = errMsgs(r.state, "tpm")[0]?.error ?? "";
  if (!/too large|413/i.test(err)) return [false, `tpm senza errore "too large" (${err.slice(0, 60) || "nessuno"})`, r.secs];
  if (calls > 2) return [false, `tpm chiamato ${calls} volte (riprova inutile)`, r.secs];
  if (!okMsgs(r.state, "ok-a", "critique").length) return [false, "ok-a senza critica: i round non sono proseguiti", r.secs];
  return [true, `done con 60.000 caratteri di allegati; tpm escluso dopo ${calls} chiamata/e: "${err.slice(0, 50)}…"`, r.secs];
};

// Annullamento mentre il ricercatore lavora: si ferma subito, nessuna risposta iniziale.
SCENARIOS.ag = async function ag() {
  const started = Date.now();
  let id;
  const p = debate("web-cancel-hang", ["ok-a", "ok-b"], 1, "ok-a", 40_000, { onStart: (x) => (id = x), extra: { webSearch: true } });
  await new Promise((res) => setTimeout(res, 1500));
  const c = await api("POST", `/api/debates/${id}/cancel`, { body: {} });
  if (c.status !== 200) return [false, `cancel → ${c.status}`, (Date.now() - started) / 1000];
  const tCancel = Date.now();
  const r = await p;
  const after = (Date.now() - tCancel) / 1000;
  if (r.state?.status !== "cancelled") return [false, `stato "${r.state?.status}" dopo l'annullamento`, r.secs];
  if (after > 3) return [false, `annullato ma dopo ${after.toFixed(1)} s`, r.secs];
  if (phaseEvent(r.events, "initial") >= 0) return [false, "la fase iniziale è partita dopo l'annullamento", r.secs];
  if (r.events.some((e) => e.type === "error" && e.phase === "research")) return [false, "annullamento registrato come errore di ricerca", r.secs];
  return [true, `cancelled ${after.toFixed(1)} s dopo la richiesta, durante la ricerca`, r.secs];
};

// Ricerca con Claude (finta CLI nel PATH, mai quella vera): solo WebSearch/WebFetch concessi, isolamento
// invariato (MCP, impostazioni, ambiente senza chiavi); da partecipante resta senza strumenti.
SCENARIOS.ah = async function ah() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const tok = randomBytes(32).toString("hex");
  const bin = await mkdtemp(join(tmpdir(), "council-chaos-bin-"));
  extraDirs.push(bin);
  await writeFile(join(bin, "claude"), `#!${process.execPath}\nprocess.stdin.resume();process.stdin.on("end",()=>{const n=Object.keys(process.env).filter(k=>/_KEY$|^COUNCIL_/.test(k));process.stdout.write(JSON.stringify({result:"ARGS"+JSON.stringify(process.argv.slice(2).filter(a=>a.length<80))+"ENV["+n.join(",")+"]"}))});\n`);
  await chmod(join(bin, "claude"), 0o755);
  const cfg = {
    providers: { chaos: { name: "Chaos", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_KEY" } },
    judge: { id: "j", label: "Giudice", kind: "openai", provider: "chaos", model: "ok-a" },
    models: [
      { id: "ok-a", label: "A", kind: "openai", provider: "chaos", model: "ok-a", family: "ok-a", default: false },
      { id: "fakeclaude", label: "Finta Claude", kind: "claude-cli", model: "sonnet", default: false },
    ],
  };
  const e = await startExtraEngine(cfg, JSON.stringify({ token: tok, keys: { CHAOS_KEY } }), { env: { PATH: `${bin}:${process.env.PATH}` } });
  const ws = (await api("GET", "/api/models", { port: e.port, headers: authed(tok) })).body?.webSearch;
  if (ws?.via !== "Claude") return [false, `/api/models webSearch = ${JSON.stringify(ws)}`, secs()];
  const c = await api("POST", "/api/debates", { port: e.port, headers: authed(tok),
    body: { question: QUESTION("web-claude"), models: ["ok-a", "fakeclaude"], rounds: 0, judge: "ok-a", claudeModel: "haiku", webSearch: true } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  let state;
  for (let i = 0; i < 100; i++) {
    state = (await api("GET", `/api/debates/${c.body.id}`, { port: e.port, headers: authed(tok) })).body;
    if (state?.status && state.status !== "running") break;
    await new Promise((res) => setTimeout(res, 300));
  }
  e.proc.kill("SIGTERM");
  if (state?.status !== "done") return [false, `stato "${state?.status}"`, secs()];
  const res = okMsgs(state, "research:fakeclaude", "research")[0];
  const part = okMsgs(state, "fakeclaude", "initial")[0];
  if (!res || !part) return [false, `ricerca ${res ? "ok" : "assente"}, partecipante ${part ? "ok" : "assente"}`, secs()];
  const args = (t) => JSON.parse(t.match(/^ARGS(\[.*\])ENV/)?.[1] ?? "[]");
  const ra = args(res.content), pa = args(part.content);
  const after = (list, flag) => list[list.indexOf(flag) + 1];
  const wrong = [];
  if (after(ra, "--tools") !== "WebSearch,WebFetch" || after(ra, "--allowedTools") !== "WebSearch,WebFetch") wrong.push(`ricerca: strumenti ${after(ra, "--tools")}`);
  if (after(pa, "--tools") !== "" || pa.includes("--allowedTools")) wrong.push(`partecipante: strumenti ${JSON.stringify(after(pa, "--tools"))}`);
  for (const f of ["--strict-mcp-config", "--no-session-persistence"]) if (!ra.includes(f)) wrong.push(`ricerca senza ${f}`);
  if (after(ra, "--setting-sources") !== "") wrong.push("ricerca con impostazioni utente");
  if (after(ra, "--model") !== "haiku") wrong.push(`ricerca con modello ${after(ra, "--model")}`);
  if (!/ENV\[\]/.test(res.content)) wrong.push(`ambiente: ${res.content.match(/ENV\[.*\]/)?.[0]}`);
  if (wrong.length) return [false, wrong.join("; "), secs()];
  return [true, "ricerca con solo WebSearch/WebFetch e isolamento invariato; partecipante senza strumenti", secs()];
};

// ---------- chat continua: turni dopo il verdetto ----------

const FQ = (tag, text) => `[scenario:${tag}] ${text}`;
const followupPath = (id) => `/api/debates/${id}/followups`;
const turnMsgs = (state, turn) => (state?.messages ?? []).filter((m) => (m.turn ?? 0) === turn);

/** Domanda di seguito: POST, poi segue il flusso del turno fino a done e rilegge lo stato. */
async function turnOf(id, body, timeoutMs) {
  const started = Date.now();
  const post = await api("POST", followupPath(id), { body: { claudeModel: "sonnet", ...body } });
  if (post.status !== 201) return { post, events: [], state: null, secs: (Date.now() - started) / 1000 };
  const { events, timedOut } = await followEvents(id, timeoutMs);
  const state = await finalState(id);
  return { post, turn: post.body?.turn, events, timedOut, state, secs: (Date.now() - started) / 1000 };
}

/** Dibattito di partenza concluso (2 modelli ok, nessun round). */
async function baseDebate(tag, extra) {
  const r = await debate(tag, ["ok-a", "ok-b"], 0, "ok-a", 60_000, { extra });
  const bad = expectDone(r, 60);
  if (bad) throw new Error(`dibattito di partenza: ${bad}`);
  return r;
}

// Risposta rapida: turno 1 con eventi tutti marcati, cronologia del turno, verdetto e titolo invariati,
// prompt con domanda originale, allegati completi, verdetto e nuova domanda (in quest'ordine).
SCENARIOS.ai = async function ai() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-quick", { attachments: [{ name: "orari.txt", kind: "text", text: "INIZIO-CONV-ALL orari dei treni FINE-CONV-ALL" }] });
  const NEWQ = FQ("conv-quick", "E se viaggio di notte?");
  const t = await turnOf(r.id, { question: NEWQ, responder: "ok-b", attachments: [{ name: "nota.txt", kind: "text", text: "INIZIO-TURNO-ALL nota del turno FINE-TURNO-ALL" }] }, 60_000);
  if (t.post.status !== 201 || t.turn !== 1) return [false, `POST followups → ${t.post.status} ${t.post.text.slice(0, 100)}`, secs()];
  const wrong = [];
  const att = turnMsgs(t.state, 1).find((m) => m.model_id === "_attachments");
  if (!att?.content?.includes("nota.txt")) wrong.push("_attachments del turno mancante");
  if (JSON.stringify(t.state).includes("FINE-TURNO-ALL")) wrong.push("testo degli allegati del turno restituito all'app");
  const first = t.events[0];
  if (first?.type !== "turn" || first.turn !== 1 || first.mode !== "quick" || first.question !== NEWQ) wrong.push(`primo evento ${JSON.stringify(first)?.slice(0, 80)}`);
  if (t.events.some((e) => e.turn !== 1)) wrong.push("eventi senza turn: 1");
  const msg = t.events.find((e) => e.type === "message");
  if (msg?.phase !== "answer" || msg.modelId !== "ok-b") wrong.push(`messaggio ${msg?.phase}/${msg?.modelId}`);
  const done = doneEvent(t.events);
  if (done?.status !== "done" || "title" in done) wrong.push(`done ${JSON.stringify(done)}`);
  if (t.state?.status !== "done") wrong.push(`stato ${t.state?.status}`);
  if (t.state?.verdict !== r.state.verdict || t.state?.title !== r.state.title) wrong.push("verdetto o titolo del turno 0 cambiati");
  const m1 = turnMsgs(t.state, 1);
  const user = m1.find((m) => m.model_id === "_user");
  if (user?.phase !== "followup" || user.content !== NEWQ) wrong.push("messaggio _user mancante");
  let meta = null;
  try { meta = JSON.parse(m1.find((m) => m.model_id === "_meta" && m.phase === "turn")?.content ?? "null"); } catch { /* sotto */ }
  if (meta?.mode !== "quick" || meta.judge !== "ok-b" || meta.webSearch !== false) wrong.push(`_meta del turno ${JSON.stringify(meta)}`);
  if (!m1.some((m) => m.model_id === "ok-b" && m.phase === "answer" && m.content)) wrong.push("risposta non salvata nel turno 1");
  if (turnMsgs(t.state, 0).length + m1.length !== t.state.messages.length) wrong.push("messaggi con turn diverso da 0/1");
  const p = (await promptsOf("conv-quick")).filter((x) => x.phase === "answer");
  if (p.length !== 1) wrong.push(`${p.length} prompt di risposta rapida`);
  else {
    const u = p[0].user;
    const at = (s) => u.indexOf(s);
    const keys = ["CONVERSAZIONE FINORA", QUESTION("conv-quick"), "FINE-CONV-ALL", r.state.verdict.slice(0, 200), `NUOVA DOMANDA:\n${NEWQ}`];
    const missing = keys.filter((k) => at(k) < 0);
    if (missing.length) wrong.push(`prompt senza: ${missing.map((k) => k.slice(0, 30)).join(" | ")}`);
    else if (at(r.state.verdict.slice(0, 200)) > at("NUOVA DOMANDA")) wrong.push("verdetto dopo la nuova domanda");
    if (at("FINE-TURNO-ALL") < at("NUOVA DOMANDA")) wrong.push("allegato del turno assente o prima della nuova domanda");
    if (/giudice/i.test(p[0].system)) wrong.push("il risponditore riceve il prompt del giudice");
  }
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs()];
  return [true, "turno 1: eventi marcati, cronologia del turno, verdetto/titolo invariati, contesto completo nel prompt", secs()];
};

// Risponditore bloccato: dopo il tempo massimo risponde una riserva della catena, e lo si dice.
SCENARIOS.aj = async function aj() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-hang");
  const t = await turnOf(r.id, { question: FQ("conv-hang", "E con i bagagli?"), responder: "hang" }, 240_000);
  if (t.post.status !== 201) return [false, `POST followups → ${t.post.status}`, secs()];
  if (t.timedOut) return [false, "nessun done entro 240 s", secs()];
  if (t.state?.status !== "done") return [false, `stato ${t.state?.status} (${doneEvent(t.events)?.error})`, secs()];
  const err = t.events.find((e) => e.type === "error" && e.modelId === "hang");
  const msg = t.events.find((e) => e.type === "message" && e.phase === "answer");
  if (!err) return [false, "nessun errore per il risponditore bloccato", secs()];
  if (!msg || msg.modelId === "hang" || !msg.text.startsWith("> Risposta di riserva")) return [false, `risposta: ${msg?.modelId} ${msg?.text.slice(0, 40)}`, secs()];
  return [true, `riserva ${msg.modelId} dopo "${err.error}"`, secs()];
};

// Domanda di seguito mentre il dibattito o un turno sono in corso: 409, nessun turno in più.
SCENARIOS.ak = async function ak() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const c = await api("POST", "/api/debates", { body: { question: QUESTION("conv-409"), models: ["slow", "ok-a"], rounds: 0, judge: "ok-a", claudeModel: "sonnet" } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  const id = c.body.id;
  const body = { question: FQ("conv-409", "E poi?"), responder: "ok-a", claudeModel: "sonnet" };
  const a = await api("POST", followupPath(id), { body });
  if (a.status !== 409) return [false, `durante il dibattito → ${a.status}`, secs()];
  const d = await followEvents(id, 60_000);
  if (doneEvent(d.events)?.status !== "done") return [false, "dibattito di partenza non concluso", secs()];
  await finalState(id);
  const t1 = await api("POST", followupPath(id), { body: { ...body, responder: "slow" } });
  if (t1.status !== 201) return [false, `primo turno → ${t1.status}`, secs()];
  const b = await api("POST", followupPath(id), { body });
  const b2 = await api("POST", followupPath(id), { body: { ...body, mode: "council", models: ["ok-a", "ok-b"], rounds: 0, judge: "ok-a" } });
  if (b.status !== 409 || b2.status !== 409) return [false, `durante il turno → ${b.status}/${b2.status}`, secs()];
  const e = await followEvents(id, 60_000);
  const st = await finalState(id);
  if (doneEvent(e.events)?.status !== "done" || st.status !== "done") return [false, `turno lento: ${st.status}`, secs()];
  // Cinque richieste insieme: un solo turno nuovo, le altre 409.
  // Risponditore lento: il turno resta in corso mentre arrivano le altre.
  const many = await Promise.all(Array.from({ length: 5 }, () => api("POST", followupPath(id), { body: { ...body, responder: "slow" } })));
  const codes = many.map((x) => x.status).sort().join(",");
  if (codes !== "201,409,409,409,409") return [false, `richieste concorrenti → ${codes}`, secs()];
  await followEvents(id, 30_000);
  const st2 = await finalState(id);
  const users = st2.messages.filter((m) => m.model_id === "_user").length;
  if (users !== 2) return [false, `${users} domande di seguito salvate (attese 2)`, secs()];
  return [true, "409 durante dibattito e turno (quick e council); 5 richieste insieme → 1 turno", secs()];
};

SCENARIOS.al = async function al() {
  const started = Date.now();
  const r = await api("POST", followupPath(987654321), { body: { question: FQ("conv-404", "x"), claudeModel: "sonnet" } });
  const secs = (Date.now() - started) / 1000;
  if (r.status !== 404) return [false, `id inesistente → ${r.status}`, secs];
  return [true, "id inesistente → 404", secs];
};

// Richieste non valide: 400/413/415, mai 500, nessun turno creato. Turno 0 senza risposte: 400.
SCENARIOS.am = async function am() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-bad");
  const base = { question: FQ("conv-bad", "E poi?"), claudeModel: "sonnet" };
  const a = (text, extra = {}) => ({ name: "a.txt", kind: "text", text, ...extra });
  const council = { mode: "council", models: ["ok-a", "ok-b"], rounds: 1, judge: "ok-a" };
  const cases = [
    ["mode sconosciuto", { mode: "fast" }, 400],
    ["mode numero", { mode: 1 }, 400],
    ["domanda vuota", { question: "   " }, 400],
    ["domanda di 20.001 caratteri", { question: "x".repeat(20_001) }, 400],
    ["responder inesistente", { responder: "nessuno" }, 400],
    ["responder numero", { responder: 42 }, 400],
    ["claudeModel sbagliato", { claudeModel: "gpt" }, 400],
    ["council con 1 modello", { ...council, models: ["ok-a"] }, 400],
    ["council models stringa", { ...council, models: "ok-a" }, 400],
    ["council 11 modelli", { ...council, models: MODELS.slice(0, 11) }, 400],
    ["council rounds 5", { ...council, rounds: 5 }, 400],
    ["council giudice inesistente", { ...council, judge: "nessuno" }, 400],
    ["webSearch stringa", { webSearch: "yes" }, 400],
    ["6 allegati", { attachments: Array(6).fill(a("x")) }, 400],
    ["allegato di 40.001 caratteri", { attachments: [a("x".repeat(40_001))] }, 400],
    ["kind sconosciuto", { attachments: [a("x", { kind: "exe" })] }, 400],
    ["corpo > 400.000 caratteri", { attachments: [a("x".repeat(410_000))] }, 413],
  ];
  const wrong = [];
  for (const [name, extra, want] of cases) {
    const x = await api("POST", followupPath(r.id), { body: { ...base, ...extra } }).catch((e) => ({ status: `errore ${e.message}` }));
    if (x.status !== want) wrong.push(`${name}: atteso ${want}, avuto ${x.status}`);
  }
  const raw = [["corpo elenco", "[]", 400], ["JSON rotto", "{", 400], ["corpo null", "null", 400]];
  for (const [name, body, want] of raw) {
    const x = await api("POST", followupPath(r.id), { body, raw: true });
    if (x.status !== want) wrong.push(`${name}: atteso ${want}, avuto ${x.status}`);
  }
  const ct = await api("POST", followupPath(r.id), { body: base, headers: { "Content-Type": "text/plain" } });
  if (ct.status !== 415) wrong.push(`text/plain → ${ct.status}`);
  // Dibattito fallito senza nessuna risposta: non c'è niente da continuare.
  const f = await debate("conv-bad-empty", ["crash500", "empty"], 0, "ok-a", 60_000);
  if (f.state?.status !== "failed") wrong.push(`dibattito vuoto: stato ${f.state?.status}`);
  const fx = await api("POST", followupPath(f.id), { body: base });
  if (fx.status !== 400) wrong.push(`turno 0 senza risposte → ${fx.status}`);
  for (const id of [r.id, f.id]) {
    const st = (await api("GET", `/api/debates/${id}`)).body;
    if (st?.messages?.some((m) => m.turn > 0)) wrong.push(`dibattito ${id}: turno creato da una richiesta non valida`);
    if (st?.status === "running") wrong.push(`dibattito ${id} rimasto running`);
  }
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs()];
  return [true, `${cases.length + raw.length + 2} richieste non valide respinte (400/413/415), nessun turno creato`, secs()];
};

// Turno "council": fasi complete marcate turn 1, verdetto del turno nel done, verdetto e titolo della
// discussione invariati; contesto completo in initial/verdict, richiamo breve nei round. Poi un turno
// rapido vede il verdetto del consiglio del turno 1.
SCENARIOS.an = async function an() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-council");
  const NEWQ = FQ("conv-council", "E per Napoli?");
  const t = await turnOf(r.id, { question: NEWQ, mode: "council", models: ["ok-a", "ok-b"], rounds: 1, judge: "ok-b" }, 120_000);
  if (t.post.status !== 201 || t.turn !== 1) return [false, `POST followups → ${t.post.status} ${t.post.text.slice(0, 100)}`, secs()];
  const wrong = [];
  if (t.events[0]?.type !== "turn" || t.events[0].mode !== "council") wrong.push("primo evento non turn/council");
  if (t.events.some((e) => e.turn !== 1)) wrong.push("eventi senza turn: 1");
  const start = t.events.find((e) => e.type === "start");
  if (start?.participants?.length !== 2) wrong.push("evento start mancante");
  for (const ph of ["initial", "critique", "verdict"]) if (phaseEvent(t.events, ph) < 0) wrong.push(`fase ${ph} mancante`);
  const done = doneEvent(t.events);
  if (done?.status !== "done" || !done.verdict || "title" in done) wrong.push(`done ${JSON.stringify(done)?.slice(0, 80)}`);
  if (t.state?.verdict !== r.state.verdict || t.state?.title !== r.state.title) wrong.push("verdetto o titolo del turno 0 cambiati");
  const m1 = turnMsgs(t.state, 1);
  for (const [id, ph] of [["ok-a", "initial"], ["ok-b", "initial"], ["ok-a", "critique"], ["judge:ok-b", "verdict"]]) {
    if (!m1.some((m) => m.model_id === id && m.phase === ph && m.content)) wrong.push(`${id}/${ph} non nel turno 1`);
  }
  const pr = (await promptsOf("conv-council")).filter((p) => p.user.includes(NEWQ));
  const by = (ph) => pr.filter((p) => p.phase === ph);
  if (!by("initial").length || by("initial").some((p) => !p.user.includes("CONVERSAZIONE FINORA") || !p.user.includes(r.state.verdict.slice(0, 200)))) wrong.push("initial senza conversazione");
  if (!by("critique").length || by("critique").some((p) => p.user.includes("CONVERSAZIONE FINORA") || !p.user.includes("CONTESTO: domanda successiva"))) wrong.push("critique senza richiamo breve");
  if (!by("verdict").length || by("verdict").some((p) => !p.user.includes("CONVERSAZIONE FINORA") || p.user.includes("TITOLO:"))) wrong.push("verdetto del turno senza conversazione o con TITOLO");
  const t2 = await turnOf(r.id, { question: FQ("conv-council", "Riassumi"), responder: "ok-a" }, 60_000);
  if (t2.turn !== 2 || t2.state?.status !== "done") wrong.push(`turno 2: ${t2.post.status} ${t2.state?.status}`);
  const q2 = (await promptsOf("conv-council")).find((p) => p.phase === "answer");
  if (!q2?.user.includes("### Verdetto del consiglio 1") || !q2.user.includes(done?.verdict?.slice(0, 100) ?? "∅")) wrong.push("il turno rapido non vede il verdetto del turno 1");
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs()];
  return [true, "turno council completo (turn 1, verdetto nel done), contesto giusto per fase, turno 2 lo vede", secs()];
};

// Annullamento durante un turno; chi si ricollega a /events riceve solo il turno in corso; poi un turno
// nuovo è ammesso.
SCENARIOS.ao = async function ao() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-cancel");
  const t1 = await turnOf(r.id, { question: FQ("conv-cancel", "Primo seguito"), responder: "ok-a" }, 60_000);
  if (t1.state?.status !== "done") return [false, `turno 1: ${t1.state?.status}`, secs()];
  const p = await api("POST", followupPath(r.id), { body: { question: FQ("conv-cancel", "Secondo seguito"), responder: "hang", claudeModel: "sonnet" } });
  if (p.status !== 201 || p.body.turn !== 2) return [false, `turno 2 → ${p.status} ${p.text.slice(0, 60)}`, secs()];
  await new Promise((res) => setTimeout(res, 800));
  const follow = followEvents(r.id, 20_000);
  await new Promise((res) => setTimeout(res, 700));
  const live = (await api("GET", `/api/debates/${r.id}`)).body;
  if (live?.status !== "running" || !live.live) return [false, `durante il turno: ${live?.status}, live ${live?.live}`, secs()];
  const tCancel = Date.now();
  const c = await api("POST", `/api/debates/${r.id}/cancel`, { body: {} });
  if (c.status !== 200) return [false, `cancel → ${c.status}`, secs()];
  const ev = await follow;
  const after = (Date.now() - tCancel) / 1000;
  const st = await finalState(r.id);
  const wrong = [];
  if (ev.events[0]?.type !== "turn" || ev.events[0].turn !== 2) wrong.push(`ricollegato: primo evento ${JSON.stringify(ev.events[0])?.slice(0, 60)}`);
  if (ev.events.some((e) => e.turn !== 2)) wrong.push("eventi di un altro turno nel flusso");
  if (doneEvent(ev.events)?.status !== "cancelled") wrong.push(`done ${doneEvent(ev.events)?.status}`);
  if (after > 3) wrong.push(`annullato dopo ${after.toFixed(1)} s`);
  if (st.status !== "cancelled") wrong.push(`stato ${st.status}`);
  if (st.verdict !== r.state.verdict) wrong.push("verdetto cambiato");
  if (turnMsgs(st, 2).some((m) => m.error && m.model_id === "hang")) wrong.push("annullamento registrato come errore");
  const t3 = await turnOf(r.id, { question: FQ("conv-cancel", "Terzo seguito"), responder: "ok-a" }, 60_000);
  if (t3.turn !== 3 || t3.state?.status !== "done") wrong.push(`turno dopo l'annullamento: ${t3.post.status} turno ${t3.turn} ${t3.state?.status}`);
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs()];
  return [true, `cancelled ${after.toFixed(1)} s dopo la richiesta, flusso solo del turno 2, turno 3 ammesso`, secs()];
};

// Dieci turni: nel prompt del decimo solo gli ultimi 6 scambi hanno la risposta, i più vecchi solo la domanda.
SCENARIOS.ap = async function ap() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-many");
  const q = (k) => FQ("conv-many", `Q-${String(k).padStart(2, "0")} come cambia?`);
  for (let k = 1; k <= 10; k++) {
    const t = await turnOf(r.id, { question: q(k), responder: k % 2 ? "ok-a" : "ok-b" }, 60_000);
    if (t.turn !== k || t.state?.status !== "done") return [false, `turno ${k}: ${t.post.status} turno ${t.turn} ${t.state?.status}`, secs()];
  }
  const last = (await promptsOf("conv-many")).find((p) => p.phase === "answer" && p.user.includes(`NUOVA DOMANDA:\n${q(10)}`));
  if (!last) return [false, "prompt del turno 10 non trovato", secs()];
  const u = last.user;
  const wrong = [];
  if (!u.includes(QUESTION("conv-many")) || !u.includes(r.state.verdict.slice(0, 200))) wrong.push("domanda originale o verdetto mancanti");
  for (let k = 1; k <= 9; k++) {
    if (!u.includes(q(k))) wrong.push(`domanda ${k} mancante`);
    const eco = u.includes(`ECO[${q(k)}]`);
    if (k >= 4 && !eco) wrong.push(`risposta ${k} mancante`);
    if (k < 4 && eco) wrong.push(`risposta ${k} presente (doveva restare solo la domanda)`);
  }
  const st = (await api("GET", `/api/debates/${r.id}`)).body;
  const turns = st.messages.map((m) => m.turn ?? 0);
  if (turns.some((x, i) => i && x < turns[i - 1])) wrong.push("messaggi non ordinati per turno");
  if (st.messages.filter((m) => m.model_id === "_user").length !== 10) wrong.push("domande di seguito salvate ≠ 10");
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs()];
  return [true, `10 turni; nel decimo prompt ${u.length} caratteri, risposte solo per i turni 4–9`, secs()];
};

// Eliminazione della discussione durante un turno: il flusso si chiude, nessuna riga orfana.
SCENARIOS.aq = async function aq() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-del");
  const p = await api("POST", followupPath(r.id), { body: { question: FQ("conv-del", "E poi?"), responder: "hang", claudeModel: "sonnet",
    attachments: [{ name: "x.txt", kind: "text", text: "testo da eliminare" }] } });
  if (p.status !== 201) return [false, `POST followups → ${p.status}`, secs()];
  const follow = followEvents(r.id, 10_000);
  await new Promise((res) => setTimeout(res, 1000));
  const d = await api("DELETE", `/api/debates/${r.id}`);
  if (d.status !== 200) return [false, `DELETE → ${d.status}`, secs()];
  const ev = await follow;
  if (ev.timedOut) return [false, "flusso ancora aperto 10 s dopo l'eliminazione", secs()];
  await new Promise((res) => setTimeout(res, 500));
  const g = await api("GET", `/api/debates/${r.id}`);
  const db = new DatabaseSync(join(dataDir, "data", "council.db"), { readOnly: true });
  const orphans = db.prepare("SELECT (SELECT COUNT(*) FROM messages WHERE debate_id = ?) + (SELECT COUNT(*) FROM attachments WHERE debate_id = ?) AS n").get(r.id, r.id).n;
  db.close();
  if (g.status !== 404) return [false, `GET dopo l'eliminazione → ${g.status}`, secs()];
  if (orphans) return [false, `${orphans} righe orfane`, secs()];
  const again = await api("POST", followupPath(r.id), { body: { question: FQ("conv-del", "x"), claudeModel: "sonnet" } });
  if (again.status !== 404) return [false, `domanda di seguito dopo l'eliminazione → ${again.status}`, secs()];
  return [true, `eliminata durante il turno: flusso chiuso (${doneEvent(ev.events)?.status ?? "senza done"}), nessuna riga orfana`, secs()];
};

// Motore ucciso durante un turno: al riavvio la discussione è interrupted, poi un turno nuovo è ammesso.
SCENARIOS.ar = async function ar() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const dir = await mkdtemp(join(tmpdir(), "council-chaos-turn-"));
  extraDirs.push(dir);
  const cfgPath = join(dir, "models.json");
  const mem = (id, model) => ({ id, label: id, kind: "openai", provider: "chaos", model, family: id, default: false });
  await writeFile(cfgPath, JSON.stringify({
    providers: { chaos: { name: "Chaos", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_KEY" } },
    judge: { id: "j", label: "Giudice", kind: "openai", provider: "chaos", model: "ok-a" },
    models: [mem("oka", "ok-a"), mem("okb", "ok-b"), mem("bloccato", "hang")],
  }));
  const boot = async () => {
    const tok = randomBytes(32).toString("hex");
    const e = await startProcess(process.execPath, ["--disable-warning=ExperimentalWarning", "src/server.ts"],
      cleanEnv({ COUNCIL_DATA: dir, COUNCIL_MODELS: cfgPath }), "COUNCIL_PORT", JSON.stringify({ token: tok, keys: { CHAOS_KEY } }));
    extraProcs.push(e.proc);
    e.proc.removeAllListeners("exit");
    e.proc.on("exit", (code) => { e.proc.exited = code ?? "signal"; });
    return { ...e, h: authed(tok) };
  };
  const waitState = async (e, id) => {
    let st;
    for (let i = 0; i < 100; i++) {
      st = (await api("GET", `/api/debates/${id}`, { port: e.port, headers: e.h })).body;
      if (st?.status && st.status !== "running") break;
      await new Promise((res) => setTimeout(res, 300));
    }
    return st;
  };
  const e1 = await boot();
  const c = await api("POST", "/api/debates", { port: e1.port, headers: e1.h,
    body: { question: QUESTION("conv-restart"), models: ["oka", "okb"], rounds: 0, judge: "oka", claudeModel: "sonnet" } });
  if (c.status !== 201) return [false, `POST /api/debates → ${c.status}`, secs()];
  const id = c.body.id;
  if ((await waitState(e1, id))?.status !== "done") return [false, "dibattito di partenza non concluso", secs()];
  const f1 = await api("POST", followupPath(id), { port: e1.port, headers: e1.h, body: { question: FQ("conv-restart", "E poi?"), responder: "bloccato", claudeModel: "sonnet" } });
  if (f1.status !== 201) return [false, `turno 1 → ${f1.status}`, secs()];
  await new Promise((res) => setTimeout(res, 1000));
  const before = (await api("GET", `/api/debates/${id}`, { port: e1.port, headers: e1.h })).body;
  if (before?.status !== "running") return [false, `prima del crash stato "${before?.status}"`, secs()];
  const gone = new Promise((res) => e1.proc.once("exit", res));
  e1.proc.kill("SIGKILL");
  await gone;
  const e2 = await boot();
  const d = (await api("GET", `/api/debates/${id}`, { port: e2.port, headers: e2.h })).body;
  const wrong = [];
  if (d?.status !== "interrupted" || d.live) wrong.push(`dopo il riavvio: ${d?.status}, live ${d?.live}`);
  if (d?.verdict == null) wrong.push("verdetto del turno 0 perso");
  const ev = await api("GET", `/api/debates/${id}/events`, { port: e2.port, headers: e2.h });
  if (ev.status !== 404) wrong.push(`eventi → ${ev.status}`);
  const f2 = await api("POST", followupPath(id), { port: e2.port, headers: e2.h, body: { question: FQ("conv-restart", "Riprendiamo"), responder: "oka", claudeModel: "sonnet" } });
  if (f2.status !== 201 || f2.body.turn !== 2) wrong.push(`turno dopo il riavvio → ${f2.status} ${f2.text.slice(0, 60)}`);
  else {
    const st = await waitState(e2, id);
    if (st?.status !== "done" || !turnMsgs(st, 2).some((m) => m.phase === "answer" && m.content)) wrong.push(`turno 2: ${st?.status}`);
  }
  e2.proc.kill("SIGTERM");
  if (wrong.length) return [false, wrong.join("; "), secs()];
  return [true, "SIGKILL durante il turno → interrupted, non live, eventi 404; turno 2 ammesso e concluso", secs()];
};

// La ricerca nella cronologia trova le domande di seguito (senza maiuscole né accenti) e la lista
// restituisce updated_at aggiornato dal turno.
SCENARIOS.as = async function as() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-search");
  const t = await turnOf(r.id, { question: FQ("conv-search", "E passando da Zanzibàr-7781?"), responder: "ok-a" }, 60_000);
  if (t.state?.status !== "done") return [false, `turno: ${t.post.status} ${t.state?.status}`, secs()];
  const l = (await api("GET", "/api/debates?q=ZANZIBAR-7781")).body ?? [];
  const row = l.find((x) => x.id === r.id);
  if (!row) return [false, `domanda di seguito non trovata (${l.length} risultati)`, secs()];
  if (l.length !== 1) return [false, `${l.length} risultati per un termine unico`, secs()];
  if (!row.updated_at || row.updated_at < row.created_at) return [false, `updated_at ${row.updated_at} (created_at ${row.created_at})`, secs()];
  const all = (await api("GET", "/api/debates")).body ?? [];
  const sorted = all.every((x, i) => !i || all[i - 1].updated_at > x.updated_at || (all[i - 1].updated_at === x.updated_at && all[i - 1].id > x.id));
  if (!sorted) return [false, "lista non ordinata per ultima attività", secs()];
  return [true, "trovata con \"ZANZIBAR-7781\" (domanda di seguito con accento), updated_at presente, lista per ultima attività", secs()];
};


// Dibattito annullato durante il giudice (risposte sì, verdetto no): il seguito è ammesso e il contesto
// porta le ultime posizioni dei membri al posto del verdetto.
SCENARIOS.at = async function at() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  let id;
  const p = debate("conv-noverdict", ["ok-a", "ok-b"], 0, "hang", 30_000, { onStart: (x) => (id = x) });
  await new Promise((res) => setTimeout(res, 1500));
  await api("POST", `/api/debates/${id}/cancel`, { body: {} });
  const r = await p;
  if (r.state?.status !== "cancelled" || r.state.verdict) return [false, `partenza: ${r.state?.status}, verdetto ${!!r.state?.verdict}`, secs()];
  const t = await turnOf(id, { question: FQ("conv-noverdict", "Allora?"), responder: "ok-a" }, 60_000);
  if (t.post.status !== 201 || t.state?.status !== "done") return [false, `seguito → ${t.post.status} ${t.state?.status}`, secs()];
  const u = (await promptsOf("conv-noverdict")).find((x) => x.phase === "answer")?.user ?? "";
  if (!u.includes("non ha emesso un verdetto") || !u.includes("### Posizione 2")) return [false, "contesto senza le posizioni dei membri", secs()];
  if (t.state.verdict) return [false, "il turno ha scritto il verdetto della discussione", secs()];
  return [true, "turno 0 annullato senza verdetto: seguito ammesso, contesto con le 2 posizioni", secs()];
};

// Turno lungo oltre i 60 s di pulizia del turno precedente: la voce in corso non deve sparire
// (live, /events e annullamento funzionano ancora).
SCENARIOS.au = async function au() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-timer");
  const p = await api("POST", followupPath(r.id), { body: { question: FQ("conv-timer", "E poi?"), responder: "hang", claudeModel: "sonnet" } });
  if (p.status !== 201) return [false, `POST followups → ${p.status}`, secs()];
  await new Promise((res) => setTimeout(res, 63_000));
  const st = (await api("GET", `/api/debates/${r.id}`)).body;
  if (!st?.live) return [false, `dopo 63 s: stato ${st?.status}, live ${st?.live} (voce del turno tolta dal timer del turno 0)`, secs()];
  const follow = followEvents(r.id, 10_000);
  await new Promise((res) => setTimeout(res, 300));
  await api("POST", `/api/debates/${r.id}/cancel`, { body: {} });
  const ev = await follow;
  if (ev.events[0]?.type !== "turn" || doneEvent(ev.events)?.status !== "cancelled") return [false, `flusso: ${ev.events.map((e) => e.type).join(",")}`, secs()];
  return [true, "dopo 63 s il turno è ancora live, flusso e annullamento funzionano", secs()];
};

// Ricerca sul web in una risposta rapida: fase research prima di answer, ricercatore con il richiamo
// alla domanda originale, dossier dopo la nuova domanda; nel turno dopo è nella conversazione.
SCENARIOS.av = async function av() {
  const started = Date.now();
  const secs = () => (Date.now() - started) / 1000;
  const r = await baseDebate("conv-web");
  const t = await turnOf(r.id, { question: FQ("conv-web", "Prezzi aggiornati?"), responder: "ok-a", webSearch: true }, 60_000);
  if (t.state?.status !== "done") return [false, `turno 1: ${t.post.status} ${t.state?.status}`, secs()];
  const wrong = [];
  const iR = phaseEvent(t.events, "research"), iA = phaseEvent(t.events, "answer");
  if (iR < 0 || iA < 0 || iR > iA) wrong.push(`fasi research ${iR}, answer ${iA}`);
  if (!turnMsgs(t.state, 1).some((m) => m.phase === "research" && m.content)) wrong.push("dossier non salvato nel turno 1");
  const pr = await promptsOf("conv-web");
  const res = pr.find((x) => x.phase === "research");
  if (!res?.user.includes("Domanda successiva in una discussione partita da")) wrong.push("ricercatore senza richiamo alla domanda originale");
  const a1 = pr.find((x) => x.phase === "answer");
  if (!a1 || a1.user.indexOf(DOSSIER_MARK) < a1.user.indexOf("NUOVA DOMANDA")) wrong.push("dossier assente dal prompt del turno");
  const t2 = await turnOf(r.id, { question: FQ("conv-web", "E quindi?"), responder: "ok-b" }, 60_000);
  const a2 = (await promptsOf("conv-web")).filter((x) => x.phase === "answer").at(-1);
  if (t2.state?.status !== "done" || !a2?.user.includes("Risultati della ricerca sul web") || a2.user.indexOf(DOSSIER_MARK) > a2.user.indexOf("NUOVA DOMANDA")) wrong.push("dossier del turno 1 non nella conversazione del turno 2");
  if (wrong.length) return [false, wrong.slice(0, 4).join("; "), secs()];
  return [true, "ricerca nel turno: research → answer, dossier nel prompt e nella conversazione dopo", secs()];
};

const DESCR = {
  y: "riavvio con dibattito running → interrupted", z: "SSE vivo durante il giudice lento",
  r: "corpo spezzato e corpi non-oggetto", s: "eliminazione a dibattito in corso", t: "SSE: ricollegamento a metà",
  u: "riga del titolo", v: "giudice con verdetto vuoto",
  w: "chiavi dall'app: provider, Claude CLI, log", x: "hello con chiavi ostili",
  p: "chiavi e token mai visibili", q: "permessi dei file dati",
  n: "voce resta sulla riserva", o: "limite token in uscita (OTPM)",
  m: "voce di famiglia: riserva se il principale si blocca",
  a: "ok-a + ok-b, 3 round", b: "ok-a + ok-b + hang, 2 round", b2: "un solo modello rimasto", c: "flaky-critique rientra", d: "ratelimit con attesa",
  e: "giudice hang → riserva", f: "html non alterato", g: "empty/crash500/gone esclusi", h: "huge 300k caratteri",
  i: "annullamento", j: "input non validi", l: "quota + length (extra)", k: "motore vivo alla fine",
  aa: "ricerca sul web via Groq finto", ab: "ricerca senza ricercatore disponibile", ac: "ricercatore bloccato",
  ad: "allegati nei prompt (e non negli approfondimenti)", ae: "allegati e webSearch non validi",
  af: "allegati al limite + Groq TPM", ag: "annullamento durante la ricerca",
  ah: "ricerca con Claude (CLI finta): strumenti e isolamento",
  ai: "chat: risposta rapida con il contesto giusto", aj: "chat: risponditore bloccato → riserva",
  ak: "chat: seguito durante dibattito/turno → 409", al: "chat: seguito su id inesistente → 404",
  am: "chat: richieste di seguito non valide", an: "chat: turno council completo",
  ao: "chat: annullamento e ricollegamento durante un turno", ap: "chat: 10 turni, contesto troncato",
  aq: "chat: eliminazione durante un turno", ar: "chat: riavvio durante un turno → interrupted",
  as: "chat: ricerca trova le domande di seguito",
  at: "chat: seguito senza verdetto (posizioni)", au: "chat: turno oltre il timer di pulizia",
  av: "chat: ricerca sul web in un turno",
};

// ---------- main ----------

async function main() {
  const only = process.argv[2]?.split(",").map((s) => s.trim()).filter(Boolean);
  dataDir = await mkdtemp(join(tmpdir(), "council-chaos-"));

  const m = await startProcess(process.execPath, [join(HERE, "mock-provider.mjs"), "0"], { ...process.env }, "MOCK_PORT");
  mock = m.proc; mockPort = m.port;

  const cfgPath = join(dataDir, "models.chaos.json");
  const member = (id) => ({ id, label: `Chaos ${id}`, kind: "openai", provider: "chaos", model: id, family: id, default: false });
  await writeFile(cfgPath, JSON.stringify({
    providers: {
      chaos: { name: "Chaos", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_KEY" },
      chaosbad: { name: "Chaos chiave rovinata", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_BAD_KEY" },
      // "groq" finto: la voce GPT-OSS fa la ricerca sul web (browser_search) negli scenari aa, ac, ag.
      groq: { name: "Groq finto", baseUrl: `http://127.0.0.1:${mockPort}/v1`, keyEnv: "CHAOS_KEY" },
    },
    // Giudice predefinito non Claude: un modello "ritirato", così la catena di riserva passa ai partecipanti.
    judge: { id: "chaos-judge", label: "Chaos giudice predefinito", kind: "openai", provider: "chaos", model: "gone" },
    // Voce di famiglia: il modello principale si blocca, deve rispondere la riserva ok-b.
    models: [...MODELS.map(member), { id: "voce", label: "Voce di famiglia", kind: "openai", provider: "chaos", family: "voce", model: "hang", fallback: ["ok-b"], default: false },
      { id: "badkey", label: "Chiave rovinata", kind: "openai", provider: "chaosbad", model: "ok-a", family: "badkey", default: false },
      { id: "gptoss", label: "GPT-OSS", kind: "openai", provider: "groq", model: "openai/gpt-oss-120b", family: "gpt-oss", default: false }],
  }, null, 2));

  // Avviato come dall'app: token sulla prima riga dello stdin, chiusura con lo stdin.
  // Ricerca sul web con tempo massimo breve (6 s invece di 180 s): scenari ac e ag.
  const env = { ...process.env, COUNCIL_DATA: dataDir, COUNCIL_MODELS: cfgPath, PORT: "0", CHAOS_KEY, CHAOS_BAD_KEY, COUNCIL_PARENT: "app",
    COUNCIL_RESEARCH_TIMEOUT_MS: String(RESEARCH_TIMEOUT_S * 1000) };
  delete env.ANTHROPIC_API_KEY;
  const e = await startProcess(process.execPath, ["--disable-warning=ExperimentalWarning", "src/server.ts"], env, "COUNCIL_PORT",
    JSON.stringify({ token: TOKEN }));
  engine = e.proc; enginePort = e.port;
  engine.removeAllListeners("exit");
  engine.on("exit", (code) => { engine.exited = code ?? "signal"; });

  // Attende la fine del controllo d'avvio (le prove ricevono sempre "OK" dal mock).
  for (let i = 0; i < 60; i++) {
    const r = await api("GET", "/api/models");
    if (r.status === 200 && !r.body.checking) break;
    await new Promise((res) => setTimeout(res, 500));
  }
  console.log(`mock :${mockPort}  motore :${enginePort}  dati ${dataDir}\n`);

  const results = [];
  const run = async (k) => {
    try {
      const [pass, why, secs] = await SCENARIOS[k]();
      results.push({ k, pass, why, secs });
    } catch (err) {
      results.push({ k, pass: false, why: `eccezione: ${err.message}`, secs: 0 });
    }
    const x = results[results.length - 1];
    console.log(`${x.pass ? "PASS" : "FAIL"} ${k}. ${DESCR[k]} — ${x.why} (${x.secs.toFixed(1)} s)`);
  };

  const keys = Object.keys(SCENARIOS).filter((k) => !only || only.includes(k));
  if (keys.includes("j")) await run("j");
  await Promise.all(keys.filter((k) => k !== "j").map(run));

  // k. dopo tutto: motore vivo e raggiungibile.
  const r = await api("GET", "/api/models").catch((err) => ({ status: err.message }));
  const alive = engine.exitCode === null && engine.exited === undefined;
  const pass = r.status === 200 && alive;
  results.push({ k: "k", pass, why: `/api/models ${r.status}, processo ${alive ? "vivo" : `terminato (${engine.exited})`}`, secs: 0 });
  console.log(`${pass ? "PASS" : "FAIL"} k. ${DESCR.k} — ${results.at(-1).why}`);
  if (!alive) console.log("Ultime righe del motore:\n" + engine.log.slice(-15).join("\n"));

  const stats = await api("GET", "/stats", { port: mockPort }).catch(() => null);
  if (stats?.body) console.log(`\nchiamate al mock: ${JSON.stringify(stats.body.calls)} (connessioni hang aperte: ${stats.body.hanging})`);

  const failed = results.filter((x) => !x.pass).length;
  console.log(`\n${results.length - failed} passati, ${failed} falliti`);
  return failed;
}

const t0 = Date.now();
main()
  .then(async (failed) => {
    console.log(`tempo totale ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    await cleanup();
    process.exit(failed ? 1 : 0);
  })
  .catch(async (err) => {
    console.error(`Errore della suite: ${err.message}`);
    if (engine?.log) console.error(engine.log.slice(-15).join("\n"));
    await cleanup();
    process.exit(1);
  });
