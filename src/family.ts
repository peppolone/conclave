// Famiglie di modelli: il consiglio è fatto di "voci", una per famiglia
// (Gemini, GPT-OSS, Qwen…). Varianti della stessa famiglia ragionano in modo simile:
// non aggiungono opinioni diverse, ma sono ottime come riserve l'una dell'altra.

interface FamilyRule { id: string; label: string; test: RegExp }

// L'ordine conta: la prima regola che corrisponde vince.
const RULES: FamilyRule[] = [
  { id: "gpt-oss", label: "GPT-OSS", test: /gpt-oss/ },
  { id: "gpt", label: "GPT", test: /(^|\/)(gpt|o\d)(-|$)/ },
  { id: "gemma", label: "Gemma", test: /gemma/ },
  { id: "gemini", label: "Gemini", test: /gemini/ },
  { id: "claude", label: "Claude", test: /claude/ },
  { id: "qwen", label: "Qwen", test: /qwen|qwq/ },
  { id: "llama", label: "Llama", test: /llama/ },
  { id: "deepseek", label: "DeepSeek", test: /deepseek/ },
  { id: "mistral", label: "Mistral", test: /mistral|ministral|magistral|codestral|pixtral|devstral/ },
  { id: "kimi", label: "Kimi", test: /kimi|moonshot/ },
  { id: "minimax", label: "MiniMax", test: /minimax/ },
  { id: "glm", label: "GLM", test: /glm|zhipu|z-ai/ },
  { id: "grok", label: "Grok", test: /grok/ },
  { id: "nemotron", label: "Nemotron", test: /nemotron/ },
  { id: "phi", label: "Phi", test: /(^|\/)phi-/ },
];

export interface Family { id: string; label: string }

export function familyOf(modelId: string): Family {
  const id = modelId.toLowerCase();
  for (const r of RULES) if (r.test.test(id)) return { id: r.id, label: r.label };
  // Sconosciuta: il nome dopo l'eventuale "fornitore/" fino al primo numero o trattino.
  const last = id.split("/").pop() ?? id;
  const base = last.split(/[-_:.\d]/).find(Boolean) ?? last;
  return { id: base, label: base.charAt(0).toUpperCase() + base.slice(1) };
}

/** Valore di `model` che lascia scegliere al motore il miglior modello della famiglia. */
export const AUTO = "auto";
