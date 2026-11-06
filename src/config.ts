import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Cartella dei dati utente (.env, models.json personalizzato, database).
 * L'app Mac la imposta su ~/Library/Application Support/AI Council;
 * con `npm start` coincide con la cartella del progetto.
 */
export const DATA_DIR = process.env.COUNCIL_DATA ?? ROOT;

if (existsSync(join(DATA_DIR, ".env"))) process.loadEnvFile(join(DATA_DIR, ".env"));

export interface Provider {
  baseUrl: string;
  keyEnv: string;
  /** Campi aggiunti a ogni richiesta di chat verso questo provider. */
  extraBody?: Record<string, unknown>;
}

export interface ModelDef {
  id: string;
  label: string;
  kind: "claude-cli" | "openai";
  provider?: string;
  model: string;
  /** Modelli di riserva dello stesso provider, provati se il principale è occupato o ritirato. */
  fallback?: string[];
  default?: boolean;
}

interface ConfigFile {
  providers: Record<string, Provider & { name?: string }>;
  judge: ModelDef;
  models: ModelDef[];
}

// COUNCIL_MODELS permette di usare un file di configurazione alternativo (es. per i test).
const modelsFile =
  process.env.COUNCIL_MODELS ??
  (existsSync(join(DATA_DIR, "models.json")) ? join(DATA_DIR, "models.json") : join(ROOT, "models.json"));
export const config: ConfigFile = JSON.parse(readFileSync(modelsFile, "utf8"));

/**
 * Scelta dei modelli fatta dall'utente nelle Impostazioni (selection.json nella cartella dati).
 * Sostituisce l'elenco predefinito di models.json; i provider restano quelli inclusi nell'app.
 */
export interface Selection {
  auto: boolean;          // all'avvio sostituisce i modelli che non rispondono
  models: ModelDef[];
}
const SELECTION_FILE = join(DATA_DIR, "selection.json");

export const selection: Selection = { auto: true, models: config.models };
if (!process.env.COUNCIL_MODELS && existsSync(SELECTION_FILE)) {
  try {
    const s = JSON.parse(readFileSync(SELECTION_FILE, "utf8")) as Partial<Selection>;
    selection.auto = s.auto ?? true;
    if (Array.isArray(s.models) && s.models.length) selection.models = s.models;
  } catch { /* file rovinato: si usano i predefiniti */ }
}
config.models = selection.models;

export function validateSelection(input: unknown): Selection {
  const s = input as Partial<Selection>;
  if (!s || !Array.isArray(s.models)) throw new Error("formato non valido");
  const seen = new Set<string>();
  const models: ModelDef[] = s.models.map((m) => {
    if (!m || typeof m.id !== "string" || typeof m.model !== "string" || typeof m.label !== "string") throw new Error("modello non valido");
    if (m.kind !== "claude-cli" && m.kind !== "openai") throw new Error(`tipo non valido per ${m.id}`);
    if (m.kind === "openai" && (!m.provider || !config.providers[m.provider])) throw new Error(`provider sconosciuto per ${m.id}`);
    if (seen.has(m.id)) throw new Error(`id duplicato: ${m.id}`);
    seen.add(m.id);
    return {
      id: m.id, label: m.label.slice(0, 60), kind: m.kind, provider: m.provider, model: m.model,
      fallback: Array.isArray(m.fallback) ? m.fallback.filter((f) => typeof f === "string") : undefined,
      default: Boolean(m.default),
    };
  });
  return { auto: s.auto !== false, models };
}

export function saveSelection(s: Selection): void {
  writeFileSync(SELECTION_FILE, JSON.stringify(s, null, 2) + "\n");
}

/** Un modello è utilizzabile se è Claude (abbonamento) o se la chiave del suo provider è impostata. */
export function isAvailable(m: ModelDef): boolean {
  if (m.kind === "claude-cli") return true;
  const p = m.provider ? config.providers[m.provider] : undefined;
  return Boolean(p && process.env[p.keyEnv]?.trim());
}

export function findModel(id: string): ModelDef | undefined {
  return config.models.find((m) => m.id === id);
}

export const PORT = Number(process.env.PORT ?? 4848);
