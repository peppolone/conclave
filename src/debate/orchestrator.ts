import { config, type ModelDef } from "../config.ts";
import { chat } from "../adapters/index.ts";
import { saveMessage, finishDebate } from "../db.ts";
import * as P from "./prompts.ts";
import { redact } from "../redact.ts";

export type Phase = "initial" | "critique" | "revise" | "final" | "verdict";

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
}

export type DebateEvent =
  | {
      type: "start";
      debateId: number;
      participants: { id: string; label: string; letter: string }[];
      rounds: Rounds;
      judge: string;
      parentId: number | null;
    }
  | { type: "phase"; phase: Phase; note?: string }
  | { type: "message"; phase: Phase; modelId: string; text: string; ms: number; model?: string; replaced?: string }
  | { type: "error"; phase: Phase; modelId: string; error: string }
  | { type: "done"; status: "done" | "failed" | "cancelled"; verdict?: string; title?: string; error?: string };

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
  // Copia con il modello Claude scelto: config non viene modificata.
  const withClaude = (m: ModelDef): ModelDef => (m.kind === "claude-cli" ? { ...m, model: opts.claudeModel } : m);
  models = models.map(withClaude);
  const chosenJudge = withClaude(opts.judge);
  const parent = opts.parentContext ? { question: opts.parentContext.question, verdict: opts.parentContext.verdict } : undefined;
  // Lettere assegnate a caso: "A" non è sempre lo stesso modello.
  const letters = shuffle(LETTERS.slice(0, models.length).split(""));
  const ds: Debater[] = models.map((def, i) => ({ def, letter: letters[i], alive: true }));
  const participants = ds.map((d) => ({ id: d.def.id, label: d.def.label, letter: d.letter }));
  // Salvate per poter rileggere a chi corrisponde ogni lettera nella cronologia.
  saveMessage(debateId, { model_id: "_meta", phase: "start", content: JSON.stringify(participants), error: null, ms: null });
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
          const budget = AbortSignal.any([signal, AbortSignal.timeout(PARTICIPANT_BUDGET_MS)]);
          const r = await chat(d.def, { system: P.SYSTEM_DEBATER, user: build(d), signal: budget });
          store(d, r.text);
          saveMessage(debateId, { model_id: d.def.id, phase: name, content: r.text, error: null, ms: r.ms, model_used: r.model, replaced: r.replaced });
          emit({ type: "message", phase: name, modelId: d.def.id, text: r.text, ms: r.ms, model: r.model, replaced: r.replaced });
        } catch (e) {
          if (signal.aborted) return;
          const raw = (e as Error).name === "TimeoutError" || /abort|timeout/i.test((e as Error).message)
            ? `nessuna risposta entro ${PARTICIPANT_BUDGET_MS / 1000} s` : redact((e as Error).message);
          // Senza risposta iniziale il modello esce; nei round successivi salta il round,
          // mantiene la posizione precedente e rientra nel round dopo.
          let error = raw;
          if (keep) { keep(d); error = `ha saltato questo round (${raw})`; } else d.alive = false;
          saveMessage(debateId, { model_id: d.def.id, phase: name, content: null, error, ms: null });
          emit({ type: "error", phase: name, modelId: d.def.id, error });
        }
      }),
    );
    if (signal.aborted) throw new Error("cancelled");
  }

  const others = (d: Debater, pick: (x: Debater) => string | undefined): P.Labeled[] =>
    alive().filter((x) => x !== d && pick(x)).map((x) => ({ label: x.letter, text: pick(x)! }));

  try {
    // Fase iniziale: risposte indipendenti.
    await phase("initial", () => P.initialPrompt(question, parent), (d, t) => (d.initial = t));

    if (opts.rounds >= 1 && alive().length < 2) {
      // Da soli non si discute: si va direttamente al verdetto, e lo si dice.
      emit({ type: "phase", phase: "critique", note: "Round saltati: ha risposto un solo modello, non c'è nessuno con cui discutere." });
      saveMessage(debateId, { model_id: "_note", phase: "critique", content: "Round saltati: ha risposto un solo modello.", error: null, ms: null });
    }
    if (opts.rounds >= 1 && alive().length >= 2) {
      // Round 1: critica incrociata. L'avvocato del diavolo è scelto a caso.
      const devil = alive()[Math.floor(Math.random() * alive().length)];
      await phase(
        "critique",
        (d) => P.critiquePrompt(question, d.initial!, others(d, (x) => x.initial), d === devil),
        (d, t) => (d.critique = t),
        () => {},
      );

      if (opts.rounds >= 2) {
        // Round 2: ognuno risponde alle critiche e rivede la propria risposta.
        const allCritiques = () => alive().filter((x) => x.critique).map((x) => ({ label: x.letter, text: x.critique! }));
        await phase("revise", (d) => P.revisePrompt(question, d.initial!, allCritiques()), (d, t) => (d.revised = t),
          (d) => { d.revised = d.initial; });

        if (opts.rounds >= 3) {
          // Arresto anticipato: se nessuno ha cambiato nulla, il round 3 non aggiunge valore.
          const changes = alive().map((d) => P.parseChanges(d.revised ?? ""));
          if (alive().length >= 2 && changes.every((c) => c === "nessuno")) {
            emit({ type: "phase", phase: "final", note: "Round 3 saltato: nessun partecipante ha cambiato posizione." });
            for (const d of alive()) d.final = d.revised;
          } else {
            await phase("final", (d) => P.finalPrompt(question, d.revised!, others(d, (x) => x.revised)), (d, t) => (d.final = t),
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
    const judges: ModelDef[] = [];
    for (const m of [chosenJudge, withClaude(config.judge), ...alive().map((d) => d.def)]) {
      if (!judges.some((j) => j.id === m.id)) judges.push(m);
    }
    const judgeUser = P.judgePrompt(question, finals, critiques, parent);
    let verdict: string | undefined;
    let title: string | null = null;
    for (const j of judges) {
      try {
        const budget = AbortSignal.any([signal, AbortSignal.timeout(JUDGE_BUDGET_MS)]);
        const r = await chat(j, { system: P.SYSTEM_JUDGE, user: judgeUser, maxTokens: 8192, signal: budget });
        const split = P.splitTitle(r.text);
        title = split.title;
        verdict = j.id === chosenJudge.id ? split.verdict : `> Giudice di riserva: ${j.label} (${chosenJudge.label} non disponibile)\n\n${split.verdict}`;
        saveMessage(debateId, { model_id: `judge:${j.id}`, phase: "verdict", content: verdict, error: null, ms: r.ms });
        emit({ type: "message", phase: "verdict", modelId: `judge:${j.id}`, text: verdict, ms: r.ms });
        break;
      } catch (e) {
        if (signal.aborted) throw new Error("cancelled");
        const error = redact((e as Error).message);
        saveMessage(debateId, { model_id: `judge:${j.id}`, phase: "verdict", content: null, error, ms: null });
        emit({ type: "error", phase: "verdict", modelId: `judge:${j.id}`, error });
      }
    }
    if (!verdict) throw new Error("Nessun giudice ha prodotto il verdetto.");

    finishDebate(debateId, "done", verdict, title);
    emit({ type: "done", status: "done", verdict, ...(title ? { title } : {}) });
  } catch (e) {
    const cancelled = signal.aborted;
    const error = cancelled ? "Dibattito annullato" : redact((e as Error).message);
    finishDebate(debateId, cancelled ? "cancelled" : "failed", null);
    emit({ type: "done", status: cancelled ? "cancelled" : "failed", error });
  }
}
