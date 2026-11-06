const $ = (s) => document.querySelector(s);

const PHASES = {
  initial: "Risposte iniziali",
  critique: "Round 1 · Critica incrociata",
  revise: "Round 2 · Revisione",
  final: "Round 3 · Posizione finale",
};

const PHASE_ORDER = ["initial", "critique", "revise", "final"];
const phaseName = (p) => PHASES[p] || p;


let models = [];
let native = false; // true quando gira dentro l'app Mac
let participants = []; // [{id, label, letter}]
let currentId = null;
let source = null;
let claudeModels = ["sonnet", "opus", "haiku"];
let defaults = { rounds: 3, judge: "claude", claudeModel: "sonnet" };
let opts = { ...defaults }; // scelte correnti del composer
let parent = null; // {id, question} quando si sta approfondendo un dibattito
// Dati del dibattito mostrato (per testata, copia ed esportazione).
let info = null; // {question, rounds, judgeLabel, claudeModel, parentId, startedAt, finishedAt}
let log = new Map(); // "fase|modello" -> {phase, modelId, text, error}
let verdictText = "";

function post(msg) {
  window.webkit?.messageHandlers?.council?.postMessage(msg);
}
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);

// ---------- Markdown minimale e sicuro (escape prima di tutto) ----------
function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function inline(s) {
  return s.replace(/&lt;br\s*\/?&gt;/gi, "<br>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
}
function md(src) {
  const lines = esc(src.replace(/\r/g, "")).split("\n");
  let html = "";
  let list = null;
  let para = [];
  let inCode = false;
  let table = [];
  const flushPara = () => { if (para.length) { html += `<p>${inline(para.join("<br>"))}</p>`; para = []; } };
  const flushList = () => { if (list) { html += `</${list}>`; list = null; } };
  const flushTable = () => {
    if (!table.length) return;
    const rows = table.filter((r) => !/^\|?\s*:?-{2,}/.test(r));
    html += "<table>" + rows.map((r, i) => {
      const cells = r.replace(/^\||\|$/g, "").split("|").map((c) => inline(c.trim()));
      const t = i === 0 ? "th" : "td";
      return "<tr>" + cells.map((c) => `<${t}>${c}</${t}>`).join("") + "</tr>";
    }).join("") + "</table>";
    table = [];
  };
  const flushAll = () => { flushPara(); flushList(); flushTable(); };

  for (const line of lines) {
    if (line.startsWith("```")) {
      flushAll();
      html += inCode ? "</code></pre>" : "<pre><code>";
      inCode = !inCode;
      continue;
    }
    if (inCode) { html += line + "\n"; continue; }
    let m;
    if (/^\s*\|.*\|\s*$/.test(line)) { flushPara(); flushList(); table.push(line.trim()); continue; }
    flushTable();
    if ((m = line.match(/^(#{1,4})\s+(.*)/))) { flushAll(); const n = Math.min(m[1].length + 1, 4); html += `<h${n}>${inline(m[2])}</h${n}>`; continue; }
    if ((m = line.match(/^\s*[-*•]\s+(.*)/))) { flushPara(); if (list !== "ul") { flushList(); html += "<ul>"; list = "ul"; } html += `<li>${inline(m[1])}</li>`; continue; }
    if ((m = line.match(/^\s*\d+[.)]\s+(.*)/))) { flushPara(); if (list !== "ol") { flushList(); html += "<ol>"; list = "ol"; } html += `<li>${inline(m[1])}</li>`; continue; }
    if ((m = line.match(/^&gt;\s?(.*)/))) { flushAll(); html += `<blockquote>${inline(m[1])}</blockquote>`; continue; }
    if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) { flushAll(); html += "<hr>"; continue; }
    if (!line.trim()) { flushAll(); continue; }
    flushList();
    para.push(line);
  }
  if (inCode) html += "</code></pre>";
  flushAll();
  return html;
}

// ---------- API ----------
async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

// ---------- Composer ----------
const SELECTED_KEY = "council.selected";
function loadSelected() {
  try { return JSON.parse(localStorage.getItem(SELECTED_KEY) || "null"); } catch { return null; }
}
function saveSelected(ids) {
  try { localStorage.setItem(SELECTED_KEY, JSON.stringify(ids)); } catch { /* storage non disponibile */ }
}
const OPTIONS_KEY = "council.options";
function loadOptions() {
  try { return JSON.parse(localStorage.getItem(OPTIONS_KEY) || "null"); } catch { return null; }
}
function saveOptions() {
  try { localStorage.setItem(OPTIONS_KEY, JSON.stringify(opts)); } catch { /* storage non disponibile */ }
}

function judgeLabelOf(id) {
  if (!id || id === "claude") return "Claude";
  return models.find((m) => m.id === id)?.label || id;
}

/**
 * Popola le pillole Round e Giudice e ripristina le scelte salvate.
 * Il modello di Claude non ha un controllo proprio: si sceglie nel menu Giudice
 * ("Claude Sonnet/Opus/Haiku") o accanto a Claude nel menu Partecipanti (stessa impostazione).
 */
function renderOptions() {
  const others = models.filter((m) => m.available && m.id !== "claude");
  const saved = loadOptions() || {};
  const r = Number(saved.rounds);
  const validJudge = (id) => id === "claude" || others.some((m) => m.id === id);
  opts = {
    rounds: [0, 1, 2, 3].includes(r) ? r : defaults.rounds,
    judge: validJudge(saved.judge) ? saved.judge : (validJudge(defaults.judge) ? defaults.judge : "claude"),
    claudeModel: claudeModels.includes(saved.claudeModel) ? saved.claudeModel : (claudeModels.includes(defaults.claudeModel) ? defaults.claudeModel : claudeModels[0]),
  };
  $("#judge").innerHTML =
    `<optgroup label="Abbonamento Claude">${claudeModels.map((c) => `<option value="claude:${esc(c)}">Claude ${esc(cap(c))}</option>`).join("")}</optgroup>`
    + (others.length ? `<optgroup label="Altri modelli">${others.map((m) => `<option value="m:${esc(m.id)}">${esc(m.label)}</option>`).join("")}</optgroup>` : "");
  syncOptions();
}

/** Testo visibile delle pillole = voce scelta nel menu nascosto. */
function updatePillValues() {
  for (const sel of document.querySelectorAll(".pill-select select")) {
    const v = sel.parentElement.querySelector(".pill-value");
    if (v) v.textContent = sel.selectedOptions[0]?.textContent ?? "";
  }
}

function syncOptions() {
  $("#rounds-select").value = String(opts.rounds);
  $("#judge").value = opts.judge === "claude" ? `claude:${opts.claudeModel}` : `m:${opts.judge}`;
  // Il selettore del modello accanto a Claude nel menu Partecipanti segue la stessa impostazione.
  const cl = document.querySelector('[data-chip="claude"] .toggle-name');
  if (cl) cl.textContent = `Claude ${cap(opts.claudeModel)}`;
  const judge = esc(opts.judge === "claude" ? `Claude ${cap(opts.claudeModel)}` : judgeLabelOf(opts.judge));
  $("#sub").innerHTML = opts.rounds === 0
    ? `I modelli rispondono in parallelo, poi <strong>${judge}</strong> emette il verdetto.`
    : `I modelli rispondono, si criticano a vicenda per ${opts.rounds} round, poi <strong>${judge}</strong> emette il verdetto.`;
  updatePillValues();
  saveOptions();
  updateHint();
}

$("#rounds-select").addEventListener("change", (ev) => { opts.rounds = Number(ev.target.value); syncOptions(); });
$("#judge").addEventListener("change", (ev) => {
  const v = ev.target.value;
  if (v.startsWith("claude:")) { opts.judge = "claude"; opts.claudeModel = v.slice(7); }
  else opts.judge = v.slice(2);
  syncOptions();
});


async function loadModels() {
  const data = await api("/api/models");
  models = data.models;
  if (Array.isArray(data.claudeModels) && data.claudeModels.length) claudeModels = data.claudeModels;
  if (data.defaults) defaults = { ...defaults, ...data.defaults };
  native = !!data.native && !!window.webkit?.messageHandlers?.council;
  document.documentElement.classList.toggle("native", native);
  $("#settings-btn").hidden = !native;
  const saved = loadSelected();
  // Si mostrano solo i modelli utilizzabili; quelli senza chiave sono riassunti in un link.
  const usable = models.filter((m) => m.available);
  const locked = models.length - usable.length;
  // Un pulsante per modello: acceso = partecipa. In fondo il collegamento per aggiungerne altri.
  $("#models").innerHTML = usable.map((m) => {
    const checked = saved ? saved.includes(m.id) : m.default;
    const name = m.id === "claude" ? `Claude ${cap(opts.claudeModel || defaults.claudeModel)}` : m.label;
    const tip = m.id === "claude"
      ? "Claude con il tuo abbonamento Pro. Il modello (Sonnet, Opus, Haiku) si sceglie dal menu Giudice."
      : `${m.label} · ${m.provider}`;
    return `<label class="toggle" data-chip="${esc(m.id)}" title="${esc(tip)}">
      <input type="checkbox" value="${esc(m.id)}" ${checked ? "checked" : ""}>
      <svg class="check" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>
      <span class="toggle-name">${esc(name)}</span>
      <span class="warn-icon" hidden aria-hidden="true">!</span>
    </label>`;
  }).join("")
    + (native ? `<button type="button" class="toggle add" data-open-models title="${locked ? `${locked} modelli richiedono una chiave API` : "Scegli altri modelli dai cataloghi"}">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>Aggiungi modelli</button>` : "");
  applyHealth(data);
  renderOptions();
}

const HEALTH_TEXT = {
  ok: "risponde", checking: "verifica in corso…", busy: "sovraccarico, riproverà",
  down: "non risponde", nokey: "manca la chiave API", unchecked: "non verificato",
};

/** Aggiorna pallini e descrizioni dei modelli con l'esito del controllo d'avvio. */
function applyHealth(data) {
  for (const m of data.models) {
    const chip = document.querySelector(`[data-chip="${CSS.escape(m.id)}"]`);
    if (!chip) continue;
    const h = m.health || { status: "unchecked" };
    chip.dataset.health = h.status;
    // Nessun colore da interpretare: compare un "!" solo se il modello ha un problema.
    const problem = h.status === "down" || h.status === "busy";
    chip.querySelector(".warn-icon").hidden = !problem;
    const base = chip.title.split("\n")[0];
    chip.title = problem ? `${base}\nAttenzione: ${HEALTH_TEXT[h.status]}${h.note ? ` — ${h.note}` : ""}` : base;
  }
  // Durante il controllo d'avvio aggiorna lo stato ogni pochi secondi.
  clearTimeout(applyHealth.timer);
  if (data.checking) {
    applyHealth.timer = setTimeout(async () => {
      try { applyHealth(await api("/api/models")); } catch { /* motore in riavvio */ }
    }, 3000);
  }
}

$("#models").addEventListener("change", updateHint);

function selectedIds() {
  return [...document.querySelectorAll("#models input:checked")].map((i) => i.value);
}

function updateHint() {
  const ids = selectedIds();
  saveSelected(ids);
  const n = ids.length;
  const available = models.filter((m) => m.available && m.id !== "claude").length;
  if (available === 0) {
    if (native) $("#hint").innerHTML = `Nessuna chiave gratuita configurata. <button class="linkish" data-open-settings>Aggiungi le chiavi API</button> (⌘,)`;
    else $("#hint").textContent = "Nessuna chiave gratuita configurata: copia .env.example in .env e inserisci le chiavi.";
  } else {
    $("#hint").textContent = n < 2
      ? "Scegli almeno 2 partecipanti cliccandoci sopra."
      : `Circa ${n * (1 + opts.rounds)} chiamate ai modelli + 1 verdetto · ⌘↩ per avviare`;
  }
  $("#start-btn").disabled = n < 2;
}

function setParent(p) {
  parent = p;
  const tag = $("#parent-tag");
  tag.hidden = !p;
  tag.querySelector("span").textContent = p ? `Approfondimento di: ${p.question}` : "";
}
$("#parent-tag .x").addEventListener("click", () => setParent(null));

async function start() {
  const question = $("#question").value.trim();
  if (!question) { $("#question").focus(); return; }
  $("#start-btn").disabled = true;
  try {
    const body = { question, models: selectedIds(), rounds: opts.rounds, judge: opts.judge, claudeModel: opts.claudeModel };
    if (parent) body.parentId = parent.id;
    const { id } = await api("/api/debates", { method: "POST", body: JSON.stringify(body) });
    showDebate(id, question);
    // Così riaprire dalla cronologia un dibattito visto prima fa scattare di nuovo hashchange.
    location.hash = String(id);
    info = { ...info, rounds: opts.rounds, judgeLabel: judgeLabelOf(opts.judge), judgeId: opts.judge, claudeModel: opts.claudeModel, parentId: parent?.id ?? null, startedAt: Date.now() };
    renderMeta();
    setParent(null);
    listen(id);
    historyChanged();
  } catch (e) {
    alert(e.message);
  } finally {
    updateHint();
  }
}

// ---------- Vista dibattito ----------
function labelOf(id) {
  if (id.startsWith("judge:")) return "Giudice";
  const p = participants.find((x) => x.id === id);
  const m = models.find((x) => x.id === id);
  const name = p?.label || m?.label || id;
  return p ? `${name} · Risposta ${p.letter}` : name;
}

/** "YYYY-MM-DD HH:MM:SS" (UTC, SQLite) -> millisecondi. */
function sqlTime(s) {
  if (!s) return null;
  const t = Date.parse(String(s).replace(" ", "T") + (/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? "" : "Z"));
  return Number.isNaN(t) ? null : t;
}

function fmtDuration(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ${s % 60} s`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}

function metaText() {
  if (!info) return "";
  const parts = [];
  if (info.rounds != null) parts.push(`${info.rounds} round`);
  if (info.judgeLabel) {
    const isClaude = info.judgeId ? info.judgeId === "claude" : info.judgeLabel === "Claude";
    parts.push(`giudice ${info.judgeLabel}${isClaude && info.claudeModel ? ` (${cap(info.claudeModel)})` : ""}`);
  }
  if (info.startedAt && info.finishedAt) parts.push(`durata ${fmtDuration(info.finishedAt - info.startedAt)}`);
  return parts.join(" · ");
}

function renderMeta() {
  let html = esc(metaText());
  if (info?.parentId) html += `${html ? " · " : ""}approfondimento di <a href="#${Number(info.parentId)}">una discussione precedente</a>`;
  $("#debate-meta").innerHTML = html;
}

function showDebate(id, question) {
  currentId = id;
  participants = [];
  info = { question };
  log = new Map();
  verdictText = "";
  $("#debate").hidden = false;
  $("#debate-q").textContent = question;
  $("#debate-meta").textContent = "";
  $("#phases").innerHTML = "";
  $("#verdict").hidden = true;
  $("#verdict").innerHTML = "";
  $("#actions").hidden = true;
  $("#action-msg").textContent = "";
  setStatus("");
  document.querySelectorAll("#history li").forEach((li) => li.classList.toggle("active", li.dataset.id === String(id)));
  // Mentre si legge un dibattito il modulo per una nuova domanda resta nascosto:
  // torna con "+ Nuova discussione" o "Approfondisci".
  $("#composer").hidden = true;
  window.scrollTo({ top: 0 });
  if (native) post({ type: "current", id: Number(id) });
}

/** Torna al composer vuoto (nessun dibattito aperto). */
function showComposer() {
  source?.close();
  currentId = null;
  location.hash = "";
  $("#debate").hidden = true;
  $("#composer").hidden = false;
  document.querySelectorAll("#history li.active").forEach((li) => li.classList.remove("active"));
  if (native) post({ type: "current", id: null });
}

function setStatus(text, cls = "") {
  $("#status").textContent = text;
  $("#status").className = `status ${cls}`;
}

function phaseEl(phase, note) {
  let el = document.querySelector(`details.phase[data-phase="${phase}"]`);
  if (!el) {
    el = document.createElement("details");
    el.className = "phase";
    el.dataset.phase = phase;
    el.open = true;
    el.innerHTML = `<summary>${esc(phaseName(phase))}<span class="note"></span></summary><div class="cards"></div>`;
    // Mantiene l'ordine delle fasi anche se arrivano fuori sequenza; quelle assenti non compaiono.
    const idx = PHASE_ORDER.indexOf(phase);
    const next = idx < 0 ? null : [...$("#phases").children].find((d) => {
      const j = PHASE_ORDER.indexOf(d.dataset.phase);
      return j > idx;
    });
    $("#phases").insertBefore(el, next || null);
  }
  if (note) el.querySelector(".note").textContent = note;
  return el;
}

function card(phase, modelId) {
  const box = phaseEl(phase).querySelector(".cards");
  let c = box.querySelector(`[data-model="${CSS.escape(modelId)}"]`);
  if (!c) {
    c = document.createElement("div");
    c.className = "card wait";
    c.dataset.model = modelId;
    c.innerHTML = `<header><strong></strong><span></span></header><div class="body md"><span class="dots">sta scrivendo…</span></div>`;
    c.querySelector("strong").textContent = labelOf(modelId);
    box.append(c);
  }
  return c;
}

function fillCard(phase, modelId, text, ms, error, used, replaced) {
  const c = card(phase, modelId);
  c.className = `card ${error ? "err" : ""}`;
  c.querySelector("span").textContent = ms ? `${(ms / 1000).toFixed(1)} s` : "";
  // Quale modello della famiglia ha risposto davvero, e se ha sostituito quello previsto.
  const sw = replaced && used
    ? `<p class="switch">Ha risposto <strong>${esc(used)}</strong> al posto di ${esc(replaced)}, che non ha risposto in tempo.</p>`
    : used ? `<p class="used">${esc(used)}</p>` : "";
  c.querySelector(".body").innerHTML = error ? esc(error) : sw + md(text);
  log.set(`${phase}|${modelId}`, { phase, modelId, text, error });
}

function showVerdict(text) {
  verdictText = text;
  $("#actions").hidden = false;
  $("#verdict").hidden = false;
  $("#verdict").innerHTML = `<div class="tag">Verdetto del consiglio</div><div class="md">${md(text)}</div>`;
  // Il dibattito completo resta consultabile, ma chiuso.
  document.querySelectorAll("details.phase").forEach((d) => (d.open = false));
}

const alive = new Set();

function handle(e) {
  switch (e.type) {
    case "start":
      participants = e.participants;
      alive.clear();
      participants.forEach((p) => alive.add(p.id));
      if (info) {
        if (e.rounds != null) info.rounds = e.rounds;
        if (e.judge) { info.judgeLabel = e.judge; if (!info.judgeId) info.judgeId = e.judge === "Claude" ? "claude" : null; }
        if (e.parentId != null) info.parentId = e.parentId;
        if (!info.startedAt) info.startedAt = Date.now();
        renderMeta();
      }
      setStatus("Dibattito in corso…");
      $("#cancel-btn").hidden = false;
      break;
    case "phase":
      if (e.phase === "verdict") { setStatus("Il giudice sta valutando…"); break; }
      phaseEl(e.phase, e.note);
      if (!e.note) alive.forEach((id) => card(e.phase, id));
      setStatus(`${phaseName(e.phase)}…`);
      break;
    case "message":
      if (e.phase === "verdict") showVerdict(e.text);
      else fillCard(e.phase, e.modelId, e.text, e.ms, null, e.model, e.replaced);
      break;
    case "error":
      if (e.phase === "verdict") setStatus(`Giudice non disponibile (${e.error.slice(0, 120)}), provo un altro modello…`, "err");
      else if (e.error.startsWith("ha saltato")) fillCard(e.phase, e.modelId, "", 0, `Ha saltato questo round e rientra nel prossimo: ${e.error.replace(/^ha saltato questo round \(|\)$/g, "")}`);
      else { alive.delete(e.modelId); fillCard(e.phase, e.modelId, "", 0, `Escluso dal dibattito: ${e.error}`); }
      break;
    case "done":
      $("#cancel-btn").hidden = true;
      if (info) { info.finishedAt = Date.now(); renderMeta(); }
      if (e.status === "done") {
        setStatus("Concluso", "ok");
        if (native) {
          const q = info?.question || "";
          post({ type: "done", title: "Verdetto pronto", body: q.length > 80 ? q.slice(0, 79) + "…" : q });
        }
      } else setStatus(e.error || e.status, "err");
      historyChanged();
      break;
  }
}

function listen(id) {
  source?.close();
  source = new EventSource(`/api/debates/${id}/events`);
  source.onmessage = (m) => {
    if (currentId !== id) return;
    const e = JSON.parse(m.data);
    handle(e);
    if (e.type === "done") source.close();
  };
  source.onerror = () => source.close();
}

async function openDebate(id) {
  source?.close();
  const d = await api(`/api/debates/${id}`);
  showDebate(id, d.question);
  const o = d.options || {};
  info = {
    question: d.question,
    rounds: o.rounds ?? null,
    judgeId: o.judge || null,
    judgeLabel: o.judge ? judgeLabelOf(o.judge) : null,
    claudeModel: o.claudeModel || null,
    parentId: d.parent_id ?? null,
    startedAt: sqlTime(d.created_at),
    finishedAt: d.live ? null : sqlTime(d.finished_at),
  };
  renderMeta();
  if (d.live) { listen(id); return; }
  const meta = d.messages.find((m) => m.model_id === "_meta");
  participants = meta ? JSON.parse(meta.content) : [];
  for (const m of d.messages) {
    if (m.model_id === "_meta") continue;
    if (m.model_id === "_note") { phaseEl(m.phase, m.content || ""); continue; }
    if (m.phase === "verdict") continue;
    fillCard(m.phase, m.model_id, m.content || "", m.ms, m.error, m.model_used, m.replaced);
  }
  if (d.verdict) showVerdict(d.verdict);
  const labels = { done: ["Concluso", "ok"], failed: ["Non riuscito", "err"], cancelled: ["Annullato", "err"], interrupted: ["Interrotto (server riavviato)", "err"] };
  const [t, c] = labels[d.status] || [d.status, ""];
  setStatus(t, c);
  $("#cancel-btn").hidden = true;
}

// ---------- Cronologia ----------
let historySeq = 0;
async function loadHistory() {
  const q = $("#search").value.trim();
  const seq = ++historySeq;
  const items = await api(q ? `/api/debates?q=${encodeURIComponent(q)}` : "/api/debates");
  if (seq !== historySeq) return; // risposta superata da una ricerca più recente
  const empty = q ? "Nessun risultato" : "Ancora nessuna discussione";
  $("#history").innerHTML = items.map((d) => `
    <li data-id="${Number(d.id)}" class="${d.id === currentId ? "active" : ""}">
      <a href="#${Number(d.id)}" title="${esc(d.question)}">${esc(d.question)}</a>
      <button class="del" title="Elimina" data-del="${Number(d.id)}">×</button>
    </li>`).join("") || `<li class="muted empty">${empty}</li>`;
}

/** L'elenco dei dibattiti è cambiato: nell'app lo dice a Swift (cronologia nativa), nel browser ricarica la barra laterale. */
function historyChanged() {
  if (native) post({ type: "history" });
  else loadHistory().catch(() => {});
}

let searchTimer = null;
$("#search").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => loadHistory().catch(() => {}), 300);
});

// ---------- Azioni sul verdetto ----------
function slug(s) {
  const out = s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60).replace(/-+$/, "");
  return out || "dibattito";
}

function exportMarkdown() {
  const out = [`# ${info?.question || ""}`, ""];
  const meta = metaText();
  if (meta) out.push(`_${meta}_`, "");
  out.push("## Verdetto", "", verdictText.trim(), "");
  const entries = [...log.values()];
  const phases = [...new Set([...PHASE_ORDER, ...entries.map((x) => x.phase)])];
  const order = (id) => { const i = participants.findIndex((p) => p.id === id); return i < 0 ? 999 : i; };
  for (const ph of phases) {
    const list = entries.filter((x) => x.phase === ph).sort((a, b) => order(a.modelId) - order(b.modelId));
    if (!list.length) continue;
    out.push(`## ${phaseName(ph)}`, "");
    for (const x of list) {
      out.push(`### ${labelOf(x.modelId)}`, "");
      out.push(x.error ? `_Escluso dal dibattito: ${x.error}_` : (x.text || "").trim(), "");
    }
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

function flash(text) {
  $("#action-msg").textContent = text;
  clearTimeout(flash.timer);
  flash.timer = setTimeout(() => ($("#action-msg").textContent = ""), 2500);
}

$("#actions").addEventListener("click", async (ev) => {
  const b = ev.target.closest("[data-action]");
  if (!b) return;
  const action = b.dataset.action;
  if (action === "copy") {
    if (native) { post({ type: "copy", text: verdictText }); flash("Copiato"); return; }
    try { await navigator.clipboard.writeText(verdictText); flash("Copiato"); } catch { flash("Copia non riuscita"); }
  } else if (action === "export") {
    const text = exportMarkdown();
    const filename = `${slug(info?.question || "")}.md`;
    if (native) { post({ type: "save", filename, text }); return; }
    const url = URL.createObjectURL(new Blob([text], { type: "text/markdown;charset=utf-8" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } else if (action === "deepen") {
    if (!currentId) return;
    setParent({ id: currentId, question: info?.question || $("#debate-q").textContent });
    $("#question").value = "";
    $("#composer").hidden = false;
    $("#composer").scrollIntoView({ behavior: "smooth", block: "start" });
    $("#question").focus({ preventScroll: true });
  }
});

$("#history").addEventListener("click", async (ev) => {
  const del = ev.target.closest("[data-del]");
  if (!del) return;
  ev.preventDefault();
  if (!confirm("Eliminare questa discussione?")) return;
  await api(`/api/debates/${del.dataset.del}`, { method: "DELETE" });
  if (String(currentId) === del.dataset.del) showComposer();
  historyChanged();
});

window.addEventListener("hashchange", () => {
  const id = Number(location.hash.slice(1));
  if (id && id !== currentId) openDebate(id).catch((e) => alert(e.message));
});

function openSettings() {
  post("openSettings");
}
$("#settings-btn").addEventListener("click", openSettings);
document.addEventListener("click", (ev) => {
  // Nell'app: cliccare un modello senza chiave o il link nel suggerimento apre le impostazioni.
  if (!native) return;
  if (ev.target.closest("[data-open-models]")) window.webkit?.messageHandlers?.council?.postMessage("openModels");
  else if (ev.target.closest("[data-open-settings]")) openSettings();
});

$("#start-btn").addEventListener("click", start);
$("#question").addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) start(); });
$("#cancel-btn").addEventListener("click", () => currentId && api(`/api/debates/${currentId}/cancel`, { method: "POST" }));
function newDiscussion() {
  showComposer();
  $("#question").value = "";
  setParent(null);
  $("#question").focus();
  if (!native) loadHistory().catch(() => {});
}
$("#new-btn").addEventListener("click", newDiscussion);

// ---------- API per l'app Mac (chiamate da Swift con evaluateJavaScript) ----------
window.council = {
  /** Apre il dibattito `id` (come un link #id della cronologia). */
  open(id) {
    const n = Number(id);
    if (!n) return;
    if (location.hash.slice(1) !== String(n)) location.hash = String(n); // hashchange -> openDebate
    else if (n !== currentId) openDebate(n).catch((e) => alert(e.message));
  },
  /** Come il pulsante "+ Nuova discussione". */
  newDiscussion,
  /** Swift ha già eliminato il dibattito via API: se era aperto si torna al composer. */
  deleted(id) {
    if (String(currentId) === String(id)) showComposer();
    historyChanged();
  },
  /** Ricarica modelli e chip (dopo il riavvio del motore). */
  reloadModels() {
    return loadModels().catch(() => {});
  },
};

await loadModels();
if (!native) await loadHistory();
const initial = Number(location.hash.slice(1));
if (initial) openDebate(initial).catch(() => {});
