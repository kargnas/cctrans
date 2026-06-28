export type TranslationMode = "loading" | "translated" | "original" | "error";

export type TranslationPreviewState = {
  mode: TranslationMode;
  sourceLanguage: string;
  targetLanguage: string;
  didReverseBecauseLanguagesMatched: boolean;
  originalText: string;
  translatedText: string;
  translatedImageURL?: string | null;
  errorText: string | null;
  providerTitle: string;
  model: string;
  modelWarning: string | null;
  costCredits: number | null;
  permissionAction?: "screenRecording" | null;
  toastDuration: number;
  requestSequence?: number;
};

export type ShowToastResult = {
  arrow: "above" | "below" | "none";
  anchorBottom: boolean;
};

export const fallbackTranslationState: TranslationPreviewState = {
  mode: "translated",
  sourceLanguage: "English",
  targetLanguage: "Korean",
  didReverseBecauseLanguagesMatched: false,
  originalText: "The future belongs to those who believe in the beauty of their dreams.",
  translatedText: "미래는 자신의 꿈의 아름다움을 믿는 사람들의 것이다.",
  translatedImageURL: null,
  errorText: null,
  providerTitle: "Local Model",
  model: "Hy-MT2 1.8B 4-bit",
  modelWarning: null,
  costCredits: null,
  toastDuration: 4
};
