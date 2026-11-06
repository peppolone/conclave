// Controllo all'avvio: verifica quali modelli del consiglio rispondono e, con la scelta
// automatica attiva, sostituisce quelli fuori uso con il migliore disponibile dello stesso provider.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { config, selection, isAvailable, DATA_DIR, saveSelection, type ModelDef } from "./config.ts";
import { listCatalog, probe, familyChain } from "./catalog.ts";
import { AUTO, familyOf } from "./family.ts";

export interface Health {
  status: "checking" | "ok" | "busy" | "down" | "nokey" | "unchecked";
  using?: string;      // modello effettivamente in uso (se diverso dal configurato)
  chain?: string[];    // ordine dei modelli da provare: primo = in uso, poi le riserve
  note?: string;
}

const health = new Map<string, Health>();

/**
 * Una variante ha risposto dopo che quelle prima di lei nella catena hanno fallito:
 * diventa la prima scelta della voce (per i round successivi e i prossimi dibattiti),
 * le varianti fallite scivolano in fondo. Si evita così di riattendere ogni volta il timeout.
 */
/** Modello lento o sparito: va in fondo alla catena della voce (resta come ultima riserva). */
export function demote(voiceId: string, model: string): void {
  const h = health.get(voiceId);
  if (!h?.chain || h.chain.length < 2 || !h.chain.includes(model)) return;
  h.chain = [...h.chain.filter((x) => x !== model), model];
  if (h.using === model) h.using = h.chain[0];
  health.set(voiceId, h);
}

export function promote(voiceId: string, model: string, failed: string[]): void {
  const h = health.get(voiceId);
  if (!h) return;
  const chain = h.chain ?? [];
  const rest = chain.filter((x) => x !== model && !failed.includes(x));
  h.using = model;
  h.chain = [model, ...rest, ...failed.filter((x) => x !== model)];
  h.note = `${failed[0]} non ha risposto: la voce ora usa ${model}`;
  health.set(voiceId, h);
}
let running: Promise<void> | null = null;

export function getHealth(id: string): Health {
  return health.get(id) ?? { status: "unchecked" };
}

/**
 * Ordine dei modelli da chiamare per una voce: la catena trovata al controllo d'avvio
 * (il primo che rispondeva, poi le altre varianti della famiglia), altrimenti quella del catalogo.
 */
export async function modelsToTry(m: ModelDef): Promise<string[]> {
  const h = health.get(m.id);
  const base = [h?.using, m.model === AUTO ? undefined : m.model, ...(h?.chain ?? []), ...(m.fallback ?? [])];
  let list = [...new Set(base.filter((x): x is string => Boolean(x)))];
  if (list.length <= 1 && m.provider) {
    try { list = [...new Set([...list, ...(await familyChain(m.provider, voiceFamily(m), m.model))])]; } catch { /* catalogo non raggiungibile */ }
  }
  return list.slice(0, 6);
}

function voiceFamily(m: ModelDef): string {
  return m.family ?? familyOf(m.model).id;
}

const MAX_REPLACEMENT_PROBES = 4;

/** Nome leggibile per un modello del catalogo (alcuni provider danno solo l'id). */
export function prettyName(name: string | undefined, id: string): string {
  if (name && name !== id) return name.replace(/\s*\(free\)\s*$/i, "").slice(0, 40);
  const last = id.split("/").pop() ?? id;
  return last
    .split(/[-_]/)
    .filter(Boolean)
    .map((w) => (/^\d+(\.\d+)?b$/i.test(w) ? w.toUpperCase() : /^(gpt|oss)$/i.test(w) ? w.toUpperCase() : w[0].toUpperCase() + w.slice(1)))
    .join(" ")
    .replace(/^GPT OSS/, "GPT-OSS")
    .slice(0, 40);
}

/** Aggiorna in modo permanente un membro del consiglio il cui modello è stato ritirato. */
function replaceForever(m: ModelDef, model: string, label: string): void {
  m.model = model;
  m.label = label;
  m.fallback = undefined;
  try { saveSelection(selection); } catch { /* resta valido almeno per questa sessione */ }
}

async function checkOne(m: ModelDef, _taken: Set<string>): Promise<void> {
  if (!isAvailable(m)) { health.set(m.id, { status: "nokey" }); return; }
  health.set(m.id, { status: "checking" });
  const provider = m.provider!;
  const fixed = m.model === AUTO ? undefined : m.model;

  // Catena della voce: modello scelto (se fisso), poi le varianti della famiglia dalla migliore.
  let chain: string[] = [];
  let catalogOk = true;
  try { chain = await familyChain(provider, voiceFamily(m), fixed); } catch { catalogOk = false; }
  chain = [...new Set([...(fixed ? [fixed] : []), ...chain, ...(m.fallback ?? [])])];
  // Modello fisso non più elencato dal provider: ritirato. La voce passa ad "Automatico".
  if (fixed && catalogOk) {
    const listed = (await listCatalog(provider)).some((c) => c.id === fixed);
    if (!listed) {
      const old = m.label;
      replaceForever(m, AUTO, familyOf(voiceFamily(m)).label);
      chain = chain.filter((x) => x !== fixed);
      health.set(m.id, { status: "checking", note: `${old} non esiste più: ora la voce sceglie da sola il modello migliore` });
    }
  }
  if (chain.length === 0) { health.set(m.id, { status: "down", note: "nessun modello di questa famiglia disponibile" }); return; }

  let lastBusy = false;
  const notes: string[] = [];
  const prevNote = health.get(m.id)?.note;
  for (const name of chain.slice(0, MAX_REPLACEMENT_PROBES)) {
    const r = await probe(provider, name);
    if (r.status === "ok") {
      const rest = chain.filter((x) => x !== name);
      const first = fixed && m.model !== AUTO ? fixed : undefined;
      const note = prevNote ?? (first && name !== first ? `${first} non risponde: uso ${name}` : undefined);
      health.set(m.id, { status: "ok", using: name, chain: [name, ...rest], note });
      return;
    }
    if (r.status === "busy") lastBusy = true;
    if (r.status === "auth") { health.set(m.id, { status: "down", note: "chiave non valida" }); return; }
    notes.push(`${name}: ${r.status}`);
  }
  health.set(m.id, lastBusy
    ? { status: "busy", chain, note: "tutte le varianti sono sovraccariche: durante il dibattito riproverà" }
    : { status: "down", chain, note: `non risponde nessuna variante (${notes.slice(0, 3).join(", ")})` });
}

/**
 * Sostituzione presa dal catalogo (non una riserva dichiarata): non va in cache,
 * così al prossimo avvio si ricontrolla e, se il modello è ritirato, si rende definitiva.
 */
function isTemporary(_m: ModelDef, h: Health): boolean {
  // Esiti senza catena (vecchio formato della cache) si ricontrollano.
  return !h.chain;
}

// ---- Memoria degli esiti ----
// I piani gratuiti hanno quote giornaliere minuscole (es. Gemini Flash: 20 richieste al giorno):
// provare ogni modello a ogni apertura dell'app ne consumerebbe una parte. Un esito positivo
// si riusa per CACHE_TTL; se nel frattempo il modello esaurisce la quota, durante il dibattito
// l'app passa comunque alle riserve.
const CACHE_FILE = join(DATA_DIR, "health.json");
const CACHE_TTL = 12 * 60 * 60_000;
type CacheEntry = { sig: string; at: number; health: Health };

function signature(m: ModelDef): string {
  return [m.provider, m.model, ...(m.fallback ?? [])].join("|");
}

function readCache(): Record<string, CacheEntry> {
  try { return JSON.parse(readFileSync(CACHE_FILE, "utf8")); } catch { return {}; }
}

function writeCache(): void {
  const out: Record<string, CacheEntry> = {};
  const now = Date.now();
  const old = readCache();
  for (const m of config.models) {
    if (m.kind !== "openai") continue;
    const h = health.get(m.id);
    if (h?.status !== "ok" || isTemporary(m, h)) continue;
    // Conserva la data della prova originale se l'esito arrivava già dalla memoria.
    const prev = old[m.id];
    out[m.id] = { sig: signature(m), at: prev && prev.sig === signature(m) && cachedIds.has(m.id) ? prev.at : now, health: h };
  }
  try { writeFileSync(CACHE_FILE, JSON.stringify(out, null, 2)); } catch { /* non essenziale */ }
}

const cachedIds = new Set<string>();

/**
 * Esegue il controllo su tutti i modelli (Claude escluso: costa limiti del Pro).
 * Con force=false riusa gli esiti positivi recenti invece di riprovare i modelli.
 */
export function runHealthCheck(force = false): Promise<void> {
  if (running) return running;
  const cache = force ? {} : readCache();
  cachedIds.clear();
  const taken = new Set<string>();
  for (const m of config.models) if (m.kind === "openai") taken.add(`${m.provider}/${m.model}`);
  // Per provider in sequenza (limiti di frequenza), provider diversi in parallelo.
  const byProvider = new Map<string, ModelDef[]>();
  for (const m of config.models) {
    if (m.kind === "claude-cli") { health.set(m.id, { status: "ok" }); continue; }
    const c = cache[m.id];
    if (c && c.sig === signature(m) && Date.now() - c.at < CACHE_TTL && isAvailable(m) && !isTemporary(m, c.health)) {
      health.set(m.id, c.health);
      cachedIds.add(m.id);
      if (c.health.using) taken.add(`${m.provider}/${c.health.using}`);
      continue;
    }
    const list = byProvider.get(m.provider!) ?? [];
    list.push(m);
    byProvider.set(m.provider!, list);
  }
  running = Promise.all(
    [...byProvider.values()].map(async (list) => { for (const m of list) await checkOne(m, taken); }),
  ).then(() => { writeCache(); running = null; });
  return running;
}

export function isChecking(): boolean {
  return running !== null;
}
