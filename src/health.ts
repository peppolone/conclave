// Controllo all'avvio: verifica quali modelli del consiglio rispondono e, con la scelta
// automatica attiva, sostituisce quelli fuori uso con il migliore disponibile dello stesso provider.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { config, selection, isAvailable, DATA_DIR, type ModelDef } from "./config.ts";
import { listCatalog, probe, type ProbeStatus } from "./catalog.ts";

export interface Health {
  status: "checking" | "ok" | "busy" | "down" | "nokey" | "unchecked";
  using?: string;      // modello effettivamente in uso (se diverso dal configurato)
  note?: string;
}

const health = new Map<string, Health>();
let running: Promise<void> | null = null;

export function getHealth(id: string): Health {
  return health.get(id) ?? { status: "unchecked" };
}

/** Modello da chiamare per primo: quello trovato funzionante al controllo. */
export function modelsToTry(m: ModelDef): string[] {
  const using = health.get(m.id)?.using;
  return [...new Set([using, m.model, ...(m.fallback ?? [])].filter((x): x is string => Boolean(x)))];
}

const MAX_REPLACEMENT_PROBES = 4;

async function checkOne(m: ModelDef, taken: Set<string>): Promise<void> {
  if (!isAvailable(m)) { health.set(m.id, { status: "nokey" }); return; }
  health.set(m.id, { status: "checking" });
  const provider = m.provider!;
  let lastBusy = false;

  // 1. Modello configurato e riserve dichiarate.
  for (const name of [m.model, ...(m.fallback ?? [])]) {
    const r = await probe(provider, name);
    if (r.status === "ok") {
      health.set(m.id, name === m.model ? { status: "ok" } : { status: "ok", using: name, note: `${m.model} non risponde: uso la riserva ${name}` });
      taken.add(`${provider}/${name}`);
      return;
    }
    if (r.status === "busy") lastBusy = true;
    if (r.status === "auth") { health.set(m.id, { status: "down", note: "chiave non valida" }); return; }
  }

  // 2. Scelta automatica: il migliore del catalogo che risponde e non è già nel consiglio.
  if (selection.auto) {
    try {
      const tried = new Set([m.model, ...(m.fallback ?? [])]);
      const candidates = (await listCatalog(provider))
        .filter((c) => c.free !== false && !tried.has(c.id) && !taken.has(`${provider}/${c.id}`))
        .slice(0, MAX_REPLACEMENT_PROBES);
      for (const c of candidates) {
        const r: { status: ProbeStatus } = await probe(provider, c.id);
        if (r.status === "ok") {
          taken.add(`${provider}/${c.id}`);
          health.set(m.id, { status: "ok", using: c.id, note: `${m.model} non disponibile: sostituito automaticamente con ${c.name}` });
          return;
        }
      }
    } catch { /* catalogo non raggiungibile: si segnala lo stato sotto */ }
  }

  health.set(m.id, lastBusy
    ? { status: "busy", note: "momentaneamente sovraccarico: durante il dibattito riproverà" }
    : { status: "down", note: "non risponde" });
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
    if (h?.status !== "ok") continue;
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
    if (c && c.sig === signature(m) && Date.now() - c.at < CACHE_TTL && isAvailable(m)) {
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
