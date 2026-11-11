// Verifica chiavi e modelli: `npm run check` (aggiungi `-- --claude` per provare anche Claude).
import { config, isAvailable } from "./config.ts";
import { chat } from "./adapters/index.ts";

const withClaude = process.argv.includes("--claude");

for (const m of config.models) {
  if (m.kind === "claude-cli" && !withClaude) {
    console.log(`·  ${m.label.padEnd(15)} saltato (usa --claude per provarlo)`);
    continue;
  }
  if (!isAvailable(m)) {
    console.log(`·  ${m.label.padEnd(15)} nessuna chiave per "${m.provider}" (Impostazioni ▸ Chiavi API o .env)`);
    continue;
  }
  try {
    const r = await chat(m, { system: "Rispondi in modo brevissimo.", user: "Scrivi solo: OK", maxTokens: 300 });
    console.log(`✓  ${m.label.padEnd(15)} ${r.ms} ms${r.model && r.model !== m.model ? ` (riserva: ${r.model})` : ""}`);
  } catch (e) {
    console.log(`✗  ${m.label.padEnd(15)} ${(e as Error).message.slice(0, 160)}`);
  }
}
