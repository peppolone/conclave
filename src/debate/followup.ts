// Chat continua: ricostruisce dal DB la conversazione che precede un turno ≥ 1
// (domanda originale, allegati, ricerca, verdetto del turno 0 e scambi successivi).
import { getConversationRows, getAttachments } from "../db.ts";
import type { Conversation, Exchange } from "./prompts.ts";

/** Messaggi che non sono risposte di un partecipante: note, metadati, domande, ricerca, giudice. */
const notAnswer = (id: string) => id.startsWith("_") || id.startsWith("research") || id.startsWith("judge:");

/** Conversazione dei turni 0…turn-1 della discussione `debateId`, con la domanda originale `question`. */
export function buildConversation(debateId: number, question: string, turn: number): Conversation {
  const rows = getConversationRows(debateId).filter((r) => r.turn < turn);
  const attachments = getAttachments(debateId)
    .filter((a) => a.turn < turn)
    .map(({ name, kind, text }) => ({ name, kind, text }));
  const research = rows
    .filter((r) => r.phase === "research" && r.content && r.model_id.startsWith("research:"))
    .map((r) => ({ text: r.content!, date: r.created_at.slice(0, 10) }));

  const turn0 = rows.filter((r) => r.turn === 0);
  const verdict = turn0.filter((r) => r.phase === "verdict" && r.content).at(-1)?.content ?? null;
  // Senza verdetto: l'ultima posizione di ogni partecipante (le fasi sono salvate in ordine).
  const last = new Map<string, string>();
  for (const r of turn0) if (r.content && !notAnswer(r.model_id)) last.set(r.model_id, r.content);

  const exchanges: Exchange[] = [];
  for (let t = 1; t < turn; t++) {
    const rs = rows.filter((r) => r.turn === t);
    const q = rs.find((r) => r.model_id === "_user")?.content;
    if (!q) continue;
    let council = false;
    try { council = JSON.parse(rs.find((r) => r.model_id === "_meta" && r.phase === "turn")?.content ?? "{}").mode === "council"; } catch { /* valore rovinato */ }
    const answer = rs.filter((r) => (r.phase === "answer" || r.phase === "verdict") && r.content).at(-1)?.content ?? null;
    exchanges.push({ question: q, answer, council });
  }
  return { question, attachments, research, verdict, answers: verdict ? [] : [...last.values()], exchanges };
}
