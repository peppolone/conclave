import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { DATA_DIR } from "./config.ts";

mkdirSync(join(DATA_DIR, "data"), { recursive: true });
const db = new DatabaseSync(join(DATA_DIR, "data", "council.db"));

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
`);
// Migrazione per DB esistenti: aggiunge le colonne mancanti.
{
  const cols = new Set((db.prepare(`PRAGMA table_info(debates)`).all() as { name: string }[]).map((c) => c.name));
  const add: [string, string][] = [["options", "TEXT"], ["parent_id", "INTEGER"], ["finished_at", "TEXT"]];
  for (const [name, type] of add) if (!cols.has(name)) db.exec(`ALTER TABLE debates ADD COLUMN ${name} ${type}`);
}
// Dibattiti rimasti a metà per un riavvio del server.
db.exec(`UPDATE debates SET status = 'interrupted' WHERE status = 'running'`);

export interface MessageRow {
  model_id: string;
  phase: string;
  content: string | null;
  error: string | null;
  ms: number | null;
}

export interface StoredOptions {
  rounds: number;
  judge: string;
  claudeModel: string;
}

export function createDebate(question: string, models: string[], options: StoredOptions, parentId: number | null = null): number {
  const r = db.prepare(`INSERT INTO debates (question, models, options, parent_id) VALUES (?, ?, ?, ?)`)
    .run(question, JSON.stringify(models), JSON.stringify(options), parentId);
  return Number(r.lastInsertRowid);
}

export function saveMessage(debateId: number, m: MessageRow): void {
  db.prepare(`INSERT INTO messages (debate_id, model_id, phase, content, error, ms) VALUES (?, ?, ?, ?, ?, ?)`)
    .run(debateId, m.model_id, m.phase, m.content, m.error, m.ms);
}

export function finishDebate(id: number, status: string, verdict: string | null): void {
  db.prepare(`UPDATE debates SET status = ?, verdict = ?, finished_at = datetime('now') WHERE id = ?`).run(status, verdict, id);
}

export function listDebates(limit = 50, q?: string) {
  const cols = `id, question, status, created_at, parent_id, finished_at`;
  const term = q?.trim();
  if (!term) return db.prepare(`SELECT ${cols} FROM debates ORDER BY id DESC LIMIT ?`).all(limit);
  const like = `%${term.replace(/[\\%_]/g, (c) => "\\" + c)}%`;
  return db
    .prepare(`SELECT ${cols} FROM debates WHERE question LIKE ? ESCAPE '\\' OR verdict LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT ?`)
    .all(like, like, limit);
}

export function getDebate(id: number) {
  const d = db.prepare(`SELECT * FROM debates WHERE id = ?`).get(id) as
    | {
        id: number; question: string; models: string; status: string; verdict: string | null; created_at: string;
        options: string | null; parent_id: number | null; finished_at: string | null;
      }
    | undefined;
  if (!d) return undefined;
  const messages = db.prepare(`SELECT model_id, phase, content, error, ms FROM messages WHERE debate_id = ? ORDER BY id`).all(id) as unknown as MessageRow[];
  let options: StoredOptions | null = null;
  try { options = d.options ? (JSON.parse(d.options) as StoredOptions) : null; } catch { /* valore rovinato */ }
  return { ...d, models: JSON.parse(d.models) as string[], options, messages };
}

export function deleteDebate(id: number): void {
  db.prepare(`DELETE FROM messages WHERE debate_id = ?`).run(id);
  db.prepare(`DELETE FROM debates WHERE id = ?`).run(id);
}
