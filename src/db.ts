import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { DATA_DIR } from "./config.ts";

mkdirSync(join(DATA_DIR, "data"), { recursive: true });
const db = new DatabaseSync(join(DATA_DIR, "data", "council.db"));

// Ricerca senza distinzione di maiuscole e accenti ("perche" trova "PERCHÉ"):
// lower() e LIKE di SQLite trattano così solo i caratteri ASCII.
const fold = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
db.function("fold", { deterministic: true }, (s) => (s == null ? null : fold(String(s))));

db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS debates (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    question    TEXT NOT NULL,
    models      TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'running',
    verdict     TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    debate_id   INTEGER NOT NULL REFERENCES debates(id) ON DELETE CASCADE,
    model_id    TEXT NOT NULL,
    phase       TEXT NOT NULL,
    content     TEXT,
    error       TEXT,
    ms          INTEGER,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS messages_debate ON messages(debate_id);
  -- Testo completo degli allegati: serve solo al motore (prompt), non torna all'app.
  -- Tabella a parte (non una colonna di debates) così SELECT * di getDebate non lo espone.
  CREATE TABLE IF NOT EXISTS attachments (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    debate_id   INTEGER NOT NULL REFERENCES debates(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    text        TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS attachments_debate ON attachments(debate_id);
`);
// Migrazione per DB esistenti: aggiunge le colonne mancanti.
{
  const cols = new Set((db.prepare(`PRAGMA table_info(debates)`).all() as { name: string }[]).map((c) => c.name));
  const add: [string, string][] = [["options", "TEXT"], ["parent_id", "INTEGER"], ["finished_at", "TEXT"], ["title", "TEXT"], ["updated_at", "TEXT"], ["confidence", "TEXT"]];
  for (const [name, type] of add) if (!cols.has(name)) db.exec(`ALTER TABLE debates ADD COLUMN ${name} ${type}`);
  // Ultima attività (turno nuovo): ordina la cronologia. Le discussioni vecchie partono dalla creazione.
  db.exec(`UPDATE debates SET updated_at = created_at WHERE updated_at IS NULL`);
  // Modello che ha risposto davvero e quello che ha sostituito (riserve della stessa famiglia).
  const mcols = new Set((db.prepare(`PRAGMA table_info(messages)`).all() as { name: string }[]).map((c) => c.name));
  for (const name of ["model_used", "replaced", "confidence"]) if (!mcols.has(name)) db.exec(`ALTER TABLE messages ADD COLUMN ${name} TEXT`);
  // Turni della chat continua: 0 = il dibattito originale (anche per tutte le righe già esistenti).
  if (!mcols.has("turn")) db.exec(`ALTER TABLE messages ADD COLUMN turn INTEGER NOT NULL DEFAULT 0`);
  const acols = new Set((db.prepare(`PRAGMA table_info(attachments)`).all() as { name: string }[]).map((c) => c.name));
  if (!acols.has("turn")) db.exec(`ALTER TABLE attachments ADD COLUMN turn INTEGER NOT NULL DEFAULT 0`);
}
// Dibattiti rimasti a metà per un riavvio del server.
db.exec(`UPDATE debates SET status = 'interrupted' WHERE status = 'running'`);

export interface MessageRow {
  model_id: string;
  phase: string;
  content: string | null;
  error: string | null;
  ms: number | null;
  model_used?: string | null;
  replaced?: string | null;
  /** Solo nei messaggi del verdetto: "alta" | "media" | "bassa" | null (riga AFFIDABILITÀ del giudice). */
  confidence?: string | null;
  /** Turno della chat (0 = dibattito originale). */
  turn?: number;
}

export interface StoredOptions {
  rounds: number;
  judge: string;
  claudeModel: string;
  /** Presente (true) solo se è stata chiesta la ricerca sul web. */
  webSearch?: boolean;
}

export function createDebate(question: string, models: string[], options: StoredOptions, parentId: number | null = null): number {
  const r = db.prepare(`INSERT INTO debates (question, models, options, parent_id, updated_at) VALUES (?, ?, ?, ?, datetime('now'))`)
    .run(question, JSON.stringify(models), JSON.stringify(options), parentId);
  return Number(r.lastInsertRowid);
}

export function saveMessage(debateId: number, m: MessageRow): void {
  // Solo se il dibattito esiste ancora: una risposta arrivata dopo l'eliminazione non lascia righe orfane.
  db.prepare(`INSERT INTO messages (debate_id, model_id, phase, content, error, ms, model_used, replaced, turn, confidence)
              SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM debates WHERE id = ?)`)
    .run(debateId, m.model_id, m.phase, m.content, m.error, m.ms, m.model_used ?? null, m.replaced ?? null, m.turn ?? 0, m.confidence ?? null, debateId);
}

export function saveAttachments(debateId: number, list: { name: string; kind: string; text: string }[], turn = 0): void {
  const ins = db.prepare(`INSERT INTO attachments (debate_id, name, kind, text, turn) VALUES (?, ?, ?, ?, ?)`);
  for (const a of list) ins.run(debateId, a.name, a.kind, a.text, turn);
}

/** Testo completo degli allegati di tutti i turni (solo per i prompt, mai restituito all'app). */
export function getAttachments(debateId: number) {
  return db.prepare(`SELECT name, kind, text, turn FROM attachments WHERE debate_id = ? ORDER BY turn, id`).all(debateId) as
    { name: string; kind: "pdf" | "text" | "image"; text: string; turn: number }[];
}

/** Messaggi con data, per ricostruire la conversazione nei turni successivi. */
export function getConversationRows(debateId: number) {
  return db.prepare(`SELECT model_id, phase, content, turn, created_at FROM messages WHERE debate_id = ? ORDER BY turn, id`).all(debateId) as
    { model_id: string; phase: string; content: string | null; turn: number; created_at: string }[];
}

/** Numero del prossimo turno (1 se la discussione ha solo il dibattito originale). */
export function nextTurn(debateId: number): number {
  const r = db.prepare(`SELECT COALESCE(MAX(turn), 0) + 1 AS n FROM messages WHERE debate_id = ?`).get(debateId) as { n: number };
  return Number(r.n);
}

/** Il turno 0 ha un verdetto o almeno una risposta di un partecipante (requisito per una domanda di seguito). */
export function hasTurnZeroContent(debateId: number): boolean {
  const r = db.prepare(`SELECT 1 FROM messages WHERE debate_id = ? AND turn = 0 AND content IS NOT NULL
                        AND substr(model_id, 1, 1) <> '_' AND model_id NOT LIKE 'research%' LIMIT 1`).get(debateId);
  return r !== undefined;
}

/** Un turno nuovo rimette la discussione in corso e la porta in cima alla cronologia. */
export function startTurn(id: number): void {
  db.prepare(`UPDATE debates SET status = 'running', updated_at = datetime('now') WHERE id = ?`).run(id);
}

/** Fine di un turno ≥ 1: cambia solo stato e ora, mai verdetto e titolo (restano quelli del turno 0). */
export function finishTurn(id: number, status: string): void {
  db.prepare(`UPDATE debates SET status = ?, finished_at = datetime('now') WHERE id = ?`).run(status, id);
}

export function finishDebate(id: number, status: string, verdict: string | null, title: string | null = null, confidence: string | null = null): void {
  db.prepare(`UPDATE debates SET status = ?, verdict = ?, title = ?, confidence = ?, finished_at = datetime('now') WHERE id = ?`).run(status, verdict, title, confidence, id);
}

export function listDebates(limit = 50, q?: string) {
  const cols = `id, question, title, status, created_at, parent_id, finished_at, updated_at, confidence`;
  // Ultima attività prima: una discussione con un turno nuovo sale in cima.
  const order = `ORDER BY updated_at DESC, id DESC`;
  const term = q?.trim();
  if (!term) return db.prepare(`SELECT ${cols} FROM debates ${order} LIMIT ?`).all(limit);
  const like = `%${fold(term).replace(/[\\%_]/g, (c) => "\\" + c)}%`;
  // Anche le domande di seguito (messaggi "_user").
  const followups = `EXISTS (SELECT 1 FROM messages m WHERE m.debate_id = debates.id AND m.model_id = '_user' AND fold(m.content) LIKE ? ESCAPE '\\')`;
  return db
    .prepare(`SELECT ${cols} FROM debates WHERE fold(question) LIKE ? ESCAPE '\\' OR fold(title) LIKE ? ESCAPE '\\' OR fold(verdict) LIKE ? ESCAPE '\\' OR ${followups} ${order} LIMIT ?`)
    .all(like, like, like, like, limit);
}

export function getDebate(id: number) {
  const d = db.prepare(`SELECT * FROM debates WHERE id = ?`).get(id) as
    | {
        id: number; question: string; title: string | null; models: string; status: string; verdict: string | null; created_at: string;
        options: string | null; parent_id: number | null; finished_at: string | null; updated_at: string | null; confidence: string | null;
      }
    | undefined;
  if (!d) return undefined;
  const messages = db.prepare(`SELECT model_id, phase, content, error, ms, model_used, replaced, turn, confidence FROM messages WHERE debate_id = ? ORDER BY turn, id`).all(id) as unknown as MessageRow[];
  let options: StoredOptions | null = null;
  try { options = d.options ? (JSON.parse(d.options) as StoredOptions) : null; } catch { /* valore rovinato */ }
  return { ...d, models: JSON.parse(d.models) as string[], options, messages };
}

export function deleteDebate(id: number): void {
  db.prepare(`DELETE FROM messages WHERE debate_id = ?`).run(id);
  db.prepare(`DELETE FROM attachments WHERE debate_id = ?`).run(id);
  db.prepare(`DELETE FROM debates WHERE id = ?`).run(id);
}

const MEDIAN_SAMPLES = 20;
/** Chiave dei verdetti in `medianMsByModel` (non può essere un id di modello). */
export const JUDGE_KEY = "\u0000judge";

/**
 * Tempo di risposta tipico: mediana degli ultimi 20 `ms` riusciti per ogni model_id (una sola query).
 * Esclude note, metadati, domande, ricerca ed errori; i verdetti (`judge:*`) vanno tutti sotto JUDGE_KEY.
 */
export function medianMsByModel(): Map<string, number> {
  const rows = db.prepare(`
    SELECT k, ms FROM (
      SELECT CASE WHEN phase = 'verdict' THEN ? ELSE model_id END AS k, ms,
             ROW_NUMBER() OVER (PARTITION BY CASE WHEN phase = 'verdict' THEN ? ELSE model_id END ORDER BY id DESC) AS rn
      FROM messages
      WHERE ms IS NOT NULL AND ms >= 0 AND error IS NULL AND content IS NOT NULL
        AND substr(model_id, 1, 1) <> '_' AND model_id NOT LIKE 'research%'
    ) WHERE rn <= ?`).all(JUDGE_KEY, JUDGE_KEY, MEDIAN_SAMPLES) as { k: string; ms: number }[];
  const by = new Map<string, number[]>();
  for (const r of rows) (by.get(r.k) ?? by.set(r.k, []).get(r.k)!).push(Number(r.ms));
  const out = new Map<string, number>();
  for (const [k, v] of by) {
    v.sort((a, b) => a - b);
    out.set(k, Math.round(v.length % 2 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2));
  }
  return out;
}
