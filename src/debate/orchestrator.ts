import { config, type ModelDef } from "../config.ts";
import { chat } from "../adapters/index.ts";
import { saveMessage, finishDebate, finishTurn, type MessageRow } from "../db.ts";
import * as P from "./prompts.ts";
import { redact } from "../redact.ts";
import { findResearcher, runResearch } from "./research.ts";

export type Phase = "research" | "initial" | "critique" | "revise" | "final" | "verdict" | "answer";

export type Rounds = 0 | 1 | 2 | 3;

export interface DebateOptions {
  /** 0 = solo risposte indipendenti, 1 = + critica, 2 = + revisione, 3 = + posizione finale. */
  rounds: Rounds;
  /** Giudice scelto (prima scelta della catena). */
  judge: ModelDef;
  /** Modello usato da Claude (kind "claude-cli"), sia come partecipante sia come giudice. */
  claudeModel: string;
  /** Approfondimento di un dibattito concluso. */
  parentContext?: P.ParentContext & { id: number };
  /** Ricerca sul web prima della fase iniziale. */
  webSearch?: boolean;
  /** Allegati (testo già estratto dall'app). Non passano agli approfondimenti. */
  attachments?: P.Attachment[];
  /** Turno della chat (0 = dibattito originale). */
  turn?: number;
  /** Turni ≥ 1: conversazione finora (vedi followup.ts). */
  conversation?: P.Conversation;
}

/** Campo `turn` presente solo nei turni ≥ 1 (assente = 0). */
export type DebateEvent = (
  | {
      type: "start";
      debateId: number;
      participants: { id: string; label: string; letter: string }[];
      rounds: Rounds;
      judge: string;
      parentId: number | null;
    }
  | { type: "phase"; phase: Phase; note?: string }
  | { type: "message"; phase: Phase; modelId: string; text: string; ms: number; model?: string; replaced?: string; confidence?: "alta" | "media" | "bassa" | null }
  | { type: "error"; phase: Phase; modelId: string; error: string }
  | { type: "done"; status: "done" | "failed" | "cancelled"; verdict?: string; title?: string; confidence?: "alta" | "media" | "bassa" | null; error?: string }
  | { type: "turn"; question: string; mode: "quick" | "council" }
) & { turn?: number };

interface Debater {
  def: ModelDef;
  letter: string;
  alive: boolean;
  initial?: string;
  critique?: string;
  revised?: string;
  final?: string;
}

const LETTERS = "ABCDEFGHIJKL";

/** Tempo massimo per un intervento (riserve e attese comprese): oltre, il modello salta il round. */
const PARTICIPANT_BUDGET_MS = 75_000;
const JUDGE_BUDGET_MS = 150_000;
/** Tempo massimo della ricerca sul web (oltre: errore non fatale). Abbreviabile solo per le prove. */
const RESEARCH_BUDGET_MS = (() => {
  const t = Number(process.env.COUNCIL_RESEARCH_TIMEOUT_MS);
  return Number.isInteger(t) && t >= 1000 && t < 180_000 ? t : 180_000;
})();

/** Dove salvare ed emettere: discussione, turno, flusso di eventi, annullamento. */
export interface TurnCtx {
  debateId: number;
  turn: number;
  emit: (e: DebateEvent) => void;
  signal: AbortSignal;
}

/** Salva un messaggio nel turno giusto. */
export function save(ctx: TurnCtx, m: MessageRow): void {
  saveMessage(ctx.debateId, { ...m, turn: ctx.turn });
}

/** Copia del modello con il modello Claude scelto: config non viene modificata. */
export const withClaudeModel = (m: ModelDef, claudeModel: string): ModelDef => (m.kind === "claude-cli" ? { ...m, model: claudeModel } : m);

/**
 * Esegue una chiamata con un tempo massimo. L'errore che ne esce è già pronto da mostrare:
 * tempo scaduto riconosciuto dal segnale (non dal testo: "504 Gateway Timeout" è un errore
 * del provider, non un nostro tempo scaduto) e chiavi mascherate.
 */
export async function withBudget<T>(ms: number, signal: AbortSignal, run: (budget: AbortSignal) => Promise<T>): Promise<T> {
  const timeout = AbortSignal.timeout(ms);
  try {
    return await run(AbortSignal.any([signal, timeout]));
  } catch (e) {
    const timedOut = timeout.aborted || (e as Error).name === "TimeoutError";
    throw new Error(timedOut ? `nessuna risposta entro ${ms / 1000} s` : redact((e as Error).message));
  }
}

/** Catena di riserve del giudice: prima la scelta, poi Claude, poi gli altri (senza doppioni). */
export function chainOf(chosen: ModelDef, others: ModelDef[], claudeModel: string): ModelDef[] {
  const chain: ModelDef[] = [];
  for (const m of [chosen, withClaudeModel(config.judge, claudeModel), ...others]) {
    if (!chain.some((j) => j.id === m.id)) chain.push(m);
  }
  return chain;
}

/**
 * Prova i modelli della catena uno alla volta (tempo massimo JUDGE_BUDGET_MS ciascuno) finché
 * `accept` non va a buon fine; ogni errore lo riceve `fail`. Annullamento: eccezione "cancelled".
 */
export async function firstInChain(
  chain: ModelDef[], ctx: TurnCtx,
  attempt: (m: ModelDef, budget: AbortSignal) => Promise<void>,
  fail: (m: ModelDef, error: string) => void,
): Promise<boolean> {
  for (const m of chain) {
    try {
      await withBudget(JUDGE_BUDGET_MS, ctx.signal, (budget) => attempt(m, budget));
      return true;
    } catch (e) {
      if (ctx.signal.aborted) throw new Error("cancelled");
      fail(m, (e as Error).message);
    }
  }
  return false;
}

/**
 * Ricerca sul web: un solo ricercatore, prima delle risposte. Ogni esito diverso dal
 * dossier (nessun ricercatore, errore, tempo scaduto) è non fatale: si prosegue senza.
 */
export async function researchPhase(ctx: TurnCtx, question: string, claudeModel: string): Promise<P.Material["research"]> {
  const who = findResearcher();
  if (!who) {
    const note = "Ricerca sul web non disponibile: serve Claude oppure una chiave Groq con GPT-OSS.";
    ctx.emit({ type: "phase", phase: "research", note });
    save(ctx, { model_id: "_note", phase: "research", content: note, error: null, ms: null });
    return undefined;
  }
  ctx.emit({ type: "phase", phase: "research" });
  try {
    const r = await withBudget(RESEARCH_BUDGET_MS, ctx.signal, (budget) => runResearch(who, question, claudeModel, budget));
    const modelId = `research:${who.def.id}`;
    save(ctx, { model_id: modelId, phase: "research", content: r.text, error: null, ms: r.ms, model_used: r.model, replaced: r.replaced });
    ctx.emit({ type: "message", phase: "research", modelId, text: r.text, ms: r.ms, model: r.model, replaced: r.replaced });
    return { text: r.text, date: new Date().toISOString().slice(0, 10) };
  } catch (e) {
    if (ctx.signal.aborted) throw new Error("cancelled");
    const error = `ricerca non riuscita, si prosegue senza (${(e as Error).message})`;
    save(ctx, { model_id: "research", phase: "research", content: null, error, ms: null });
    ctx.emit({ type: "error", phase: "research", modelId: "research", error });
    return undefined;
  }
}

/** Esito finale di un turno: il turno 0 scrive verdetto e titolo, gli altri solo lo stato. */
function finish(ctx: TurnCtx, status: "done" | "failed" | "cancelled", verdict: string | null, title: string | null = null, confidence: string | null = null) {
  if (ctx.turn === 0) finishDebate(ctx.debateId, status, verdict, title, confidence);
  else finishTurn(ctx.debateId, status);
}

function shuffle<T>(a: T[]): T[] {
  const r = [...a];
  for (let i = r.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [r[i], r[j]] = [r[j], r[i]];
  }
  return r;
}

export async function runDebate(
  debateId: number,
  question: string,
  models: ModelDef[],
  opts: DebateOptions,
  emit: (e: DebateEvent) => void,
  signal: AbortSignal,
): Promise<void> {
  const turn = opts.turn ?? 0;
  // Nei turni ≥ 1 ogni evento porta il numero del turno.
  if (turn > 0) { const out = emit; emit = (e) => out({ ...e, turn }); }
  const ctx: TurnCtx = { debateId, turn, emit, signal };
  const withClaude = (m: ModelDef): ModelDef => withClaudeModel(m, opts.claudeModel);
  models = models.map(withClaude);
  const chosenJudge = withClaude(opts.judge);
  const parent = opts.parentContext ? { question: opts.parentContext.question, verdict: opts.parentContext.verdict } : undefined;
  // Lettere assegnate a caso: "A" non è sempre lo stesso modello.
  const letters = shuffle(LETTERS.slice(0, models.length).split(""));
  const ds: Debater[] = models.map((def, i) => ({ def, letter: letters[i], alive: true }));
  const participants = ds.map((d) => ({ id: d.def.id, label: d.def.label, letter: d.letter }));
  // Salvate per poter rileggere a chi corrisponde ogni lettera nella cronologia.
  save(ctx, { model_id: "_meta", phase: "start", content: JSON.stringify(participants), error: null, ms: null });
  // Solo i metadati: il testo completo resta nella tabella degli allegati, non torna all'app.
  if (opts.attachments?.length) {
    const meta = opts.attachments.map((a) => ({ name: a.name, kind: a.kind, chars: a.text.length }));
    save(ctx, { model_id: "_attachments", phase: "start", content: JSON.stringify(meta), error: null, ms: null });
  }
  const material: P.Material = {
    attachments: opts.attachments?.length ? opts.attachments : undefined,
    followup: opts.conversation && turn > 0
      ? { conversation: P.conversationBlock(opts.conversation, false), original: opts.conversation.question }
      : undefined,
  };
  emit({
    type: "start", debateId, participants,
    rounds: opts.rounds, judge: chosenJudge.label, parentId: opts.parentContext?.id ?? null,
  });

  const alive = () => ds.filter((d) => d.alive);

  /** Esegue una fase in parallelo su tutti i partecipanti ancora attivi. */
  async function phase(name: Phase, build: (d: Debater) => string, store: (d: Debater, t: string) => void,
                       keep?: (d: Debater) => void) {
    emit({ type: "phase", phase: name });
    await Promise.all(
      alive().map(async (d) => {
        try {
          // Ogni intervento ha un tempo massimo: un modello bloccato non ferma il dibattito.
          const r = await withBudget(PARTICIPANT_BUDGET_MS, signal, (budget) => chat(d.def, { system: P.SYSTEM_DEBATER, user: build(d), signal: budget }));
          store(d, r.text);
          save(ctx, { model_id: d.def.id, phase: name, content: r.text, error: null, ms: r.ms, model_used: r.model, replaced: r.replaced });
          emit({ type: "message", phase: name, modelId: d.def.id, text: r.text, ms: r.ms, model: r.model, replaced: r.replaced });
        } catch (e) {
          if (signal.aborted) return;
          const raw = (e as Error).message;
          // Senza risposta iniziale il modello esce; nei round successivi salta il round,
          // mantiene la posizione precedente e rientra nel round dopo.
          let error = raw;
          if (keep) { keep(d); error = `ha saltato questo round (${raw})`; } else d.alive = false;
          save(ctx, { model_id: d.def.id, phase: name, content: null, error, ms: null });
          emit({ type: "error", phase: name, modelId: d.def.id, error });
        }
      }),
    );
    if (signal.aborted) throw new Error("cancelled");
  }

  const others = (d: Debater, pick: (x: Debater) => string | undefined): P.Labeled[] =>
    alive().filter((x) => x !== d && pick(x)).map((x) => ({ label: x.letter, text: pick(x)! }));

  try {
    if (opts.webSearch) {
      const q = material.followup ? P.followupResearchQuestion(question, material.followup.original) : question;
      material.research = await researchPhase(ctx, q, opts.claudeModel);
    }

    // Fase iniziale: risposte indipendenti.
    await phase("initial", () => P.initialPrompt(question, parent, material), (d, t) => (d.initial = t));

    if (opts.rounds >= 1 && alive().length === 1) {
      // Da soli non si discute: si va direttamente al verdetto, e lo si dice.
      emit({ type: "phase", phase: "critique", note: "Round saltati: ha risposto un solo modello, non c'è nessuno con cui discutere." });
      save(ctx, { model_id: "_note", phase: "critique", content: "Round saltati: ha risposto un solo modello.", error: null, ms: null });
    }
    if (opts.rounds >= 1 && alive().length >= 2) {
      // Round 1: critica incrociata. L'avvocato del diavolo è scelto a caso.
      const devil = alive()[Math.floor(Math.random() * alive().length)];
      await phase(
        "critique",
        (d) => P.critiquePrompt(question, d.initial!, others(d, (x) => x.initial), d === devil, material),
        (d, t) => (d.critique = t),
        () => {},
      );

      if (opts.rounds >= 2) {
        // Round 2: ognuno risponde alle critiche e rivede la propria risposta.
        const allCritiques = () => alive().filter((x) => x.critique).map((x) => ({ label: x.letter, text: x.critique! }));
        await phase("revise", (d) => P.revisePrompt(question, d.initial!, allCritiques(), material), (d, t) => (d.revised = t),
          (d) => { d.revised = d.initial; });

        if (opts.rounds >= 3) {
          // Arresto anticipato: se nessuno ha cambiato nulla, il round 3 non aggiunge valore.
          const changes = alive().map((d) => P.parseChanges(d.revised ?? ""));
          if (alive().length >= 2 && changes.every((c) => c === "nessuno")) {
            const note = "Round 3 saltato: nessun partecipante ha cambiato posizione.";
            emit({ type: "phase", phase: "final", note });
            // Salvata come le altre note: riaprendo la discussione si vede perché manca il round.
            save(ctx, { model_id: "_note", phase: "final", content: note, error: null, ms: null });
            for (const d of alive()) d.final = d.revised;
          } else {
            await phase("final", (d) => P.finalPrompt(question, d.revised!, others(d, (x) => x.revised), material), (d, t) => (d.final = t),
              (d) => { d.final = d.revised; });
          }
        }
      }
    }

    const finals = alive()
      .map((d) => ({ label: d.letter, text: d.final ?? d.revised ?? d.initial ?? "" }))
      .filter((f) => f.text);
    if (finals.length === 0) throw new Error("Nessun modello ha risposto. Controlla le chiavi con: npm run check");
    const critiques = ds.filter((d) => d.critique).map((d) => ({ label: d.letter, text: d.critique! }));

    // Verdetto: prima il giudice scelto, poi Claude, poi gli altri partecipanti attivi
    // (es. se Claude ha raggiunto il limite Pro).
    emit({ type: "phase", phase: "verdict" });
    const judges = chainOf(chosenJudge, alive().map((d) => d.def), opts.claudeModel);
    const initials = ds.filter((d) => d.initial).map((d) => ({ label: d.letter, text: d.initial! }));
    const judgeUser = P.judgePrompt(question, finals, critiques, parent, material, initials);
    let verdict: string | undefined;
    let title: string | null = null;
    let confidence: P.Confidence = null;
    await firstInChain(judges, ctx, async (j, budget) => {
      const r = await chat(j, { system: P.SYSTEM_JUDGE, user: judgeUser, maxTokens: 8192, signal: budget });
      // Riga TITOLO e riga AFFIDABILITÀ in qualunque ordine: si tolgono entrambe dal verdetto.
      const split = P.splitTitle(r.text);
      const conf = P.splitConfidence(split.verdict);
      split.verdict = conf.verdict;
      // Solo la riga del titolo, niente verdetto: si prova il giudice successivo.
      if (!split.verdict.trim()) throw new Error("verdetto vuoto");
      // Nei turni ≥ 1 il titolo della discussione non cambia.
      title = turn === 0 ? split.title : null;
      confidence = conf.confidence;
      verdict = j.id === chosenJudge.id ? split.verdict : `> Giudice di riserva: ${j.label} (${chosenJudge.label} non disponibile)\n\n${split.verdict}`;
      save(ctx, { model_id: `judge:${j.id}`, phase: "verdict", content: verdict, error: null, ms: r.ms, confidence });
      emit({ type: "message", phase: "verdict", modelId: `judge:${j.id}`, text: verdict, ms: r.ms, confidence });
    }, (j, error) => {
      save(ctx, { model_id: `judge:${j.id}`, phase: "verdict", content: null, error, ms: null });
      emit({ type: "error", phase: "verdict", modelId: `judge:${j.id}`, error });
    });
    if (!verdict) throw new Error("Nessun giudice ha prodotto il verdetto.");

    finish(ctx, "done", verdict, title, confidence);
    emit({ type: "done", status: "done", verdict, ...(title ? { title } : {}), confidence });
  } catch (e) {
    const cancelled = signal.aborted;
    const error = cancelled ? (turn > 0 ? "Turno annullato" : "Dibattito annullato") : redact((e as Error).message);
    finish(ctx, cancelled ? "cancelled" : "failed", null);
    emit({ type: "done", status: cancelled ? "cancelled" : "failed", error });
  }
}

export interface QuickOptions {
  /** Risponditore scelto (prima scelta della catena, come il giudice). */
  responder: ModelDef;
  claudeModel: string;
  /** Riserve oltre a Claude: i partecipanti del dibattito originale. */
  fallbacks: ModelDef[];
  webSearch?: boolean;
  attachments?: P.Attachment[];
  conversation: P.Conversation;
}

/**
 * Risposta rapida a una domanda di seguito (turno ≥ 1): risponde un solo modello, con la catena di
 * riserve e il tempo massimo del giudice. Eventi: phase "answer" → message o error → done.
 */
export async function runQuickAnswer(
  debateId: number, turn: number, question: string, opts: QuickOptions,
  emit: (e: DebateEvent) => void, signal: AbortSignal,
): Promise<void> {
  const out = emit;
  emit = (e) => out({ ...e, turn });
  const ctx: TurnCtx = { debateId, turn, emit, signal };
  const chosen = withClaudeModel(opts.responder, opts.claudeModel);
  const material: P.Material = { attachments: opts.attachments?.length ? opts.attachments : undefined };
  try {
    if (opts.webSearch) {
      material.research = await researchPhase(ctx, P.followupResearchQuestion(question, opts.conversation.question), opts.claudeModel);
    }
    emit({ type: "phase", phase: "answer" });
    const user = P.quickPrompt(question, P.conversationBlock(opts.conversation, true), material);
    const chain = chainOf(chosen, opts.fallbacks.map((m) => withClaudeModel(m, opts.claudeModel)), opts.claudeModel);
    const ok = await firstInChain(chain, ctx, async (m, budget) => {
      const r = await chat(m, { system: P.SYSTEM_RESPONDER, user, signal: budget });
      if (!r.text.trim()) throw new Error("risposta vuota");
      const text = m.id === chosen.id ? r.text : `> Risposta di riserva: ${m.label} (${chosen.label} non disponibile)\n\n${r.text}`;
      save(ctx, { model_id: m.id, phase: "answer", content: text, error: null, ms: r.ms, model_used: r.model, replaced: r.replaced });
      emit({ type: "message", phase: "answer", modelId: m.id, text, ms: r.ms, model: r.model, replaced: r.replaced });
    }, (m, error) => {
      save(ctx, { model_id: m.id, phase: "answer", content: null, error, ms: null });
      emit({ type: "error", phase: "answer", modelId: m.id, error });
    });
    if (!ok) throw new Error("Nessun modello ha risposto alla domanda.");
    finishTurn(debateId, "done");
    emit({ type: "done", status: "done" });
  } catch (e) {
    const cancelled = signal.aborted;
    finishTurn(debateId, cancelled ? "cancelled" : "failed");
    emit({ type: "done", status: cancelled ? "cancelled" : "failed", error: cancelled ? "Turno annullato" : redact((e as Error).message) });
  }
}
