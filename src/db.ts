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
  const add: [string, string][] = [["options", "TEXT"], ["parent_id", "INTEGER"], ["finished_at", "TEXT"], ["title", "TEXT"]];
  for (const [name, type] of add) if (!cols.has(name)) db.exec(`ALTER TABLE debates ADD COLUMN ${name} ${type}`);
  // Modello che ha risposto davvero e quello che ha sostituito (riserve della stessa famiglia).
  const mcols = new Set((db.prepare(`PRAGMA table_info(messages)`).all() as { name: string }[]).map((c) => c.name));
  for (const name of ["model_used", "replaced"]) if (!mcols.has(name)) db.exec(`ALTER TABLE messages ADD COLUMN ${name} TEXT`);
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
}

export interface StoredOptions {
  rounds: number;
  judge: string;
  claudeModel: string;
  /** Presente (true) solo se è stata chiesta la ricerca sul web. */
  webSearch?: boolean;
}

export function createDebate(question: string, models: string[], options: StoredOptions, parentId: number | null = null): number {
  const r = db.prepare(`INSERT INTO debates (question, models, options, parent_id) VALUES (?, ?, ?, ?)`)
    .run(question, JSON.stringify(models), JSON.stringify(options), parentId);
  return Number(r.lastInsertRowid);
}

export function saveMessage(debateId: number, m: MessageRow): void {
  // Solo se il dibattito esiste ancora: una risposta arrivata dopo l'eliminazione non lascia righe orfane.
  db.prepare(`INSERT INTO messages (debate_id, model_id, phase, content, error, ms, model_used, replaced)
              SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM debates WHERE id = ?)`)
    .run(debateId, m.model_id, m.phase, m.content, m.error, m.ms, m.model_used ?? null, m.replaced ?? null, debateId);
}

export function saveAttachments(debateId: number, list: { name: string; kind: string; text: string }[]): void {
  const ins = db.prepare(`INSERT INTO attachments (debate_id, name, kind, text) VALUES (?, ?, ?, ?)`);
  for (const a of list) ins.run(debateId, a.name, a.kind, a.text);
}

export function finishDebate(id: number, status: string, verdict: string | null, title: string | null = null): void {
  db.prepare(`UPDATE debates SET status = ?, verdict = ?, title = ?, finished_at = datetime('now') WHERE id = ?`).run(status, verdict, title, id);
}

export function listDebates(limit = 50, q?: string) {
  const cols = `id, question, title, status, created_at, parent_id, finished_at`;
  const term = q?.trim();
  if (!term) return db.prepare(`SELECT ${cols} FROM debates ORDER BY id DESC LIMIT ?`).all(limit);
  const like = `%${fold(term).replace(/[\\%_]/g, (c) => "\\" + c)}%`;
  return db
    .prepare(`SELECT ${cols} FROM debates WHERE fold(question) LIKE ? ESCAPE '\\' OR fold(title) LIKE ? ESCAPE '\\' OR fold(verdict) LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT ?`)
    .all(like, like, like, limit);
}

export function getDebate(id: number) {
  const d = db.prepare(`SELECT * FROM debates WHERE id = ?`).get(id) as
    | {
        id: number; question: string; title: string | null; models: string; status: string; verdict: string | null; created_at: string;
        options: string | null; parent_id: number | null; finished_at: string | null;
      }
    | undefined;
  if (!d) return undefined;
  const messages = db.prepare(`SELECT model_id, phase, content, error, ms, model_used, replaced FROM messages WHERE debate_id = ? ORDER BY id`).all(id) as unknown as MessageRow[];
  let options: StoredOptions | null = null;
  try { options = d.options ? (JSON.parse(d.options) as StoredOptions) : null; } catch { /* valore rovinato */ }
  return { ...d, models: JSON.parse(d.models) as string[], options, messages };
}

export function deleteDebate(id: number): void {
  db.prepare(`DELETE FROM messages WHERE debate_id = ?`).run(id);
  db.prepare(`DELETE FROM attachments WHERE debate_id = ?`).run(id);
  db.prepare(`DELETE FROM debates WHERE id = ?`).run(id);
}
