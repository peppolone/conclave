// Prompt delle fasi del dibattito. I partecipanti si vedono solo come
// "Risposta A/B/C": nessuno sa quale modello ha scritto cosa.

const LANG = `Lingua: rispondi sempre nella stessa lingua in cui è scritta la DOMANDA (se è in inglese rispondi in inglese, se è in spagnolo in spagnolo, e così via), anche se queste istruzioni sono in italiano.`;

const MAX_CHARS = 4500; // tetto per testo citato: i piani gratuiti hanno limiti di token stretti

const clip = (s: string) => (s.length > MAX_CHARS ? s.slice(0, MAX_CHARS) + "\n[…testo troncato]" : s);

export const SYSTEM_DEBATER = `Sei un membro di un consiglio di esperti indipendenti che discute una domanda per arrivare alla risposta migliore possibile.
Regole:
- ${LANG}
- Sii preciso e concreto.
- Distingui fatti verificabili, stime e opinioni. Se non sai qualcosa, dillo.
- Non inventare fonti, numeri o citazioni.
- Cambia idea se un argomento altrui è migliore: l'obiettivo è la verità, non vincere.
- Massimo 350 parole per intervento.`;

export const SYSTEM_JUDGE = `Sei il giudice imparziale di un consiglio di esperti AI. Non hai partecipato al dibattito.
Valuti la qualità degli argomenti, non il numero di voti: tre posizioni concordi possono essere sbagliate.
Rispondi in Markdown.
${LANG} Traduci nella lingua della domanda anche i titoli delle sezioni del verdetto.`;

export type Labeled = { label: string; text: string };

const block = (items: Labeled[]) => items.map((i) => `### Risposta ${i.label}\n${clip(i.text)}`).join("\n\n");

export type ParentContext = { question: string; verdict: string };

const PARENT_VERDICT_MAX = 3000;

/** Blocco in testa ai prompt quando il dibattito approfondisce una discussione precedente. */
function contextBlock(parent?: ParentContext): string {
  if (!parent) return "";
  const v = parent.verdict.length > PARENT_VERDICT_MAX ? parent.verdict.slice(0, PARENT_VERDICT_MAX) + "\n[…testo troncato]" : parent.verdict;
  return `CONTESTO — DISCUSSIONE PRECEDENTE:\nDomanda: ${parent.question}\nVerdetto: ${v}\n\n`;
}

export function initialPrompt(question: string, parent?: ParentContext): string {
  return `${contextBlock(parent)}DOMANDA:\n${question}\n\nDai la tua risposta indipendente, con il ragionamento essenziale.`;
}

export function critiquePrompt(question: string, own: string, others: Labeled[], devil: boolean): string {
  const role = devil
    ? `\nRUOLO SPECIALE: sei l'AVVOCATO DEL DIAVOLO. Individua la risposta che sembra più convincente (anche la tua) e attaccane i punti deboli con il massimo rigore.`
    : "";
  return `DOMANDA:\n${question}\n\nLA TUA RISPOSTA INIZIALE:\n${clip(own)}\n\nRISPOSTE DEGLI ALTRI MEMBRI:\n${block(others)}
${role}
Round 1 — Critica. Per ciascuna risposta degli altri indica: errori di fatto, ragionamenti deboli, cose importanti mancanti, punti in cui hanno ragione loro e non tu. Sii specifico e cita la lettera della risposta.`;
}

export function revisePrompt(question: string, own: string, critiques: Labeled[]): string {
  return `DOMANDA:\n${question}\n\nLA TUA RISPOSTA INIZIALE:\n${clip(own)}\n\nCRITICHE FORMULATE DAI MEMBRI DEL CONSIGLIO (riguardano tutte le risposte, inclusa la tua):\n${block(critiques)}

Round 2 — Revisione. Rispondi alle critiche che ti riguardano: accetta quelle fondate, respingi motivatamente le altre. Poi scrivi la tua risposta rivista.
Termina con una riga esattamente in questo formato (la parola CAMBIAMENTI e i valori restano in italiano, qualunque sia la lingua della risposta):
CAMBIAMENTI: nessuno | minori | sostanziali`;
}

export function finalPrompt(question: string, own: string, others: Labeled[]): string {
  return `DOMANDA:\n${question}\n\nLA TUA RISPOSTA RIVISTA:\n${clip(own)}\n\nRISPOSTE RIVISTE DEGLI ALTRI MEMBRI:\n${block(others)}

Round 3 — Posizione finale. Tenendo conto delle revisioni altrui, scrivi la tua conclusione definitiva. Indica in una riga finale "FIDUCIA: alta | media | bassa".`;
}

export function judgePrompt(question: string, finals: Labeled[], critiques: Labeled[], parent?: ParentContext): string {
  const crit = critiques.length
    ? `\n\nCRITICHE EMERSE NEL DIBATTITO (estratto):\n${block(critiques.map((c) => ({ ...c, text: c.text.slice(0, 1500) })))}`
    : "";
  return `${contextBlock(parent)}DOMANDA ORIGINALE:\n${question}

POSIZIONI FINALI DEI MEMBRI:\n${block(finals)}${crit}

Inizia con una riga esattamente in questo formato (la parola TITOLO resta in italiano, il titolo è nella lingua della domanda):
TITOLO: titolo breve della discussione, al massimo 6 parole, senza virgolette né punto finale
Poi produci il verdetto con queste sezioni:
## Risposta
La risposta migliore alla domanda, completa e autonoma (puoi combinare elementi di più posizioni).
## Su cosa concordano
## Errori emersi nel dibattito
## Disaccordi irrisolti
## Affidabilità
alta / media / bassa, con il motivo e cosa servirebbe verificare.`;
}

/** Legge la riga "CAMBIAMENTI: ..." del round 2. */
export function parseChanges(text: string): "nessuno" | "minori" | "sostanziali" | "?" {
  const m = text.match(/CAMBIAMENTI:\s*\**\s*(nessuno|minori|sostanziali)/i);
  if (m) return m[1].toLowerCase() as "nessuno" | "minori" | "sostanziali";
  // Qualche modello traduce comunque la riga: si accetta anche la forma inglese.
  const en = text.match(/CHANGES:\s*\**\s*(none|minor|substantial)/i)?.[1].toLowerCase();
  return en === "none" ? "nessuno" : en === "minor" ? "minori" : en === "substantial" ? "sostanziali" : "?";
}

/** Toglie dal verdetto la riga "TITOLO: ..." e la restituisce come titolo della discussione. */
export function splitTitle(text: string): { title: string | null; verdict: string } {
  const m = text.match(/^\s*\**\s*(?:TITOLO|TITLE)\s*:\s*\**\s*(.+?)\s*\**\s*$/im);
  if (!m || m.index! > 200) return { title: null, verdict: text };
  const title = m[1].replace(/^["'«“#\s]+|["'»”.\s]+$/g, "").slice(0, 80) || null;
  const verdict = (text.slice(0, m.index) + text.slice(m.index! + m[0].length)).replace(/^\s+/, "");
  return { title, verdict };
}
