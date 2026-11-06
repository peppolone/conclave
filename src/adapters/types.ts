export interface ChatRequest {
  system: string;
  user: string;
  maxTokens?: number;
  signal?: AbortSignal;
}

export interface ChatResult {
  text: string;
  ms: number;
  /** Modello che ha risposto davvero (può essere una riserva). */
  model?: string;
}
