import { config, type ModelDef } from "../config.ts";
import { modelsToTry } from "../health.ts";
import { chatClaude } from "./claude-cli.ts";
import { chatOpenAI } from "./openai-compat.ts";
import type { ChatRequest, ChatResult } from "./types.ts";

export type { ChatRequest, ChatResult } from "./types.ts";

export async function chat(m: ModelDef, req: ChatRequest): Promise<ChatResult> {
  if (m.kind === "claude-cli") return chatClaude(m.model, req);
  const p = m.provider ? config.providers[m.provider] : undefined;
  if (!p) throw new Error(`provider "${m.provider}" non definito in models.json`);
  // Catena della voce: il modello che rispondeva al controllo d'avvio, poi le altre varianti.
  const list = await modelsToTry(m);
  if (list.length === 0) throw new Error("nessun modello disponibile per questa voce");
  const r = await chatOpenAI(p, list, req);
  // Se ha risposto una riserva lo si segnala (lo mostra la chat).
  return { ...r, replaced: r.model && r.model !== list[0] ? list[0] : undefined };
}
