// Prompt delle fasi del dibattito. I partecipanti si vedono solo come
// "Risposta A/B/C": nessuno sa quale modello ha scritto cosa.

const MAX_CHARS = 4500; // tetto per testo citato: i piani gratuiti hanno limiti di token stretti

const clip = (s: string) => (s.length > MAX_CHARS ? s.slice(0, MAX_CHARS) + "\n[…testo troncato]" : s);

export const SYSTEM_DEBATER = `Sei un membro di un consiglio di esperti indipendenti che discute una domanda per arrivare alla risposta migliore possibile.
Regole:
- Rispondi in italiano, in modo preciso e concreto.
- Distingui fatti verificabili, stime e opinioni. Se non sai qualcosa, dillo.
- Non inventare fonti, numeri o citazioni.
- Cambia idea se un argomento altrui è migliore: l'obiettivo è la verità, non vincere.
- Massimo 350 parole per intervento.`;

export const SYSTEM_JUDGE = `Sei il giudice imparziale di un consiglio di esperti AI. Non hai partecipato al dibattito.
Valuti la qualità degli argomenti, non il numero di voti: tre posizioni concordi possono essere sbagliate.
Rispondi in italiano, in Markdown.`;

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
Termina con una riga esattamente in questo formato:
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

Produci il verdetto con queste sezioni:
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
  return m ? (m[1].toLowerCase() as "nessuno" | "minori" | "sostanziali") : "?";
}
