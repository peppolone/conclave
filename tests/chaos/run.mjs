// Test di stress del motore ("cerca di rompere le cose").
// Uso: npm run test:chaos   (oppure node tests/chaos/run.mjs [lettere scenari, es. "a,d,j"])
//
// Avvia il provider finto e il motore con dati e configurazione temporanei, esegue gli
// scenari via API e stampa PASS/FAIL. Non usa mai Claude e non tocca la cartella dati reale.

import { spawn } from "node:child_process";
import { request } from "node:http";
import { connect } from "node:net";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm, writeFile, stat, readdir } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { MODELS, FAKE_GOOGLE_KEY } from "./mock-provider.mjs";

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
  for (const p of [engine, mock]) {
    if (p && p.exitCode === null && !p.killed) p.kill("SIGTERM");
  }
  if (dataDir) await rm(dataDir, { recursive: true, force: true }).catch(() => {});
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

async function debate(tag, models, rounds, judge, timeoutMs, { onStart } = {}) {
  const started = Date.now();
  const r = await api("POST", "/api/debates", { body: { question: QUESTION(tag), models, rounds, judge, claudeModel: "sonnet" } });
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
      ["corpo > 100 kB", { body: { ...base, question: "x".repeat(150_000) } }, 413],
      ["senza token", { body: base, headers: { Authorization: "" } }, 401],
      ["token sbagliato", { body: base, headers: { Authorization: `Bearer ${"0".repeat(64)}` } }, 401],
      ["token come cookie/query", { body: base, headers: { Authorization: "", Cookie: `token=${TOKEN}` } }, 401],
    ];
    const wrong = [];
    for (const [name, opts, want] of cases) {
      const r = await api("POST", "/api/debates", opts).catch((e) => ({ status: `errore ${e.message}` }));
      // Per gli ultimi casi (non richiesti) basta un 4xx: nessun dibattito avviato, nessun 500.
      const lenient = ["JSON rovinato", "models non array", "rounds stringa", "corpo > 100 kB"].includes(name);
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

const DESCR = {
  r: "corpo spezzato e corpi non-oggetto", s: "eliminazione a dibattito in corso", t: "SSE: ricollegamento a metà",
  u: "riga del titolo", v: "giudice con verdetto vuoto",
  p: "chiavi e token mai visibili", q: "permessi dei file dati",
  n: "voce resta sulla riserva", o: "limite token in uscita (OTPM)",
  m: "voce di famiglia: riserva se il principale si blocca",
  a: "ok-a + ok-b, 3 round", b: "ok-a + ok-b + hang, 2 round", b2: "un solo modello rimasto", c: "flaky-critique rientra", d: "ratelimit con attesa",
  e: "giudice hang → riserva", f: "html non alterato", g: "empty/crash500/gone esclusi", h: "huge 300k caratteri",
  i: "annullamento", j: "input non validi", l: "quota + length (extra)", k: "motore vivo alla fine",
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
    },
    // Giudice predefinito non Claude: un modello "ritirato", così la catena di riserva passa ai partecipanti.
    judge: { id: "chaos-judge", label: "Chaos giudice predefinito", kind: "openai", provider: "chaos", model: "gone" },
    // Voce di famiglia: il modello principale si blocca, deve rispondere la riserva ok-b.
    models: [...MODELS.map(member), { id: "voce", label: "Voce di famiglia", kind: "openai", provider: "chaos", family: "voce", model: "hang", fallback: ["ok-b"], default: false },
      { id: "badkey", label: "Chiave rovinata", kind: "openai", provider: "chaosbad", model: "ok-a", family: "badkey", default: false }],
  }, null, 2));

  // Avviato come dall'app: token sulla prima riga dello stdin, chiusura con lo stdin.
  const env = { ...process.env, COUNCIL_DATA: dataDir, COUNCIL_MODELS: cfgPath, PORT: "0", CHAOS_KEY, CHAOS_BAD_KEY, COUNCIL_PARENT: "app" };
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
