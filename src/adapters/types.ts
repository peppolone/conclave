export interface ChatRequest {
  system: string;
  user: string;
  maxTokens?: number;
  signal?: AbortSignal;
  /** Un modello della catena non ha risposto in tempo o non esiste più (per spostarlo in fondo). */
  onModelFail?: (model: string) => void;
}

export interface ChatResult {
  text: string;
  ms: number;
  /** Modello che ha risposto davvero (può essere una riserva). */
  model?: string;
  /** Modello che doveva rispondere e non l'ha fatto, se ha risposto una riserva. */
  replaced?: string;
}
