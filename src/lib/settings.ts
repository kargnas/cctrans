export type TranslationProvider = "localHyMT2" | "openRouter" | "appleTranslation";
export type ToastPosition = "bottomRight" | "bottomLeft" | "topRight" | "topLeft" | "custom";

export type SettingField =
  | "provider"
  | "localModelID"
  | "sourceLanguage"
  | "targetLanguage"
  | "toastPosition"
  | "localHyMT2BackendPath"
  | "customLocalModelsPath"
  | "openRouterTextModel"
  | "openRouterVisionModel"
  | "openRouterModelFilter"
  | "favoriteLocalModelIDs"
  | "favoriteOpenRouterModels";

export type OpenRouterModelFilter = {
  modalityMode: "textOrVision" | "all";
  minPromptPricePerMillion: number;
  maxPromptPricePerMillion: number;
  minCompletionPricePerMillion: number;
  maxCompletionPricePerMillion: number;
};

export type Settings = {
  provider: TranslationProvider;
  localModelID: string;
  localHyMT2BackendPath: string | null;
  customLocalModelsPath: string | null;
  openRouterTextModel: string;
  openRouterVisionModel: string;
  openRouterModelFilter: OpenRouterModelFilter;
  favoriteLocalModelIDs: string[];
  favoriteOpenRouterModels: string[];
  includeScreenContextForLLM: boolean;
  sourceLanguage: string;
  targetLanguage: string;
  hasCompletedLocalModelSelection: boolean;
  toastPosition: ToastPosition;
  toastCustomPosition: { x: number; y: number } | null;
  toastDuration: number;
};

export type SettingOption = {
  label: string;
  value: string;
  note?: string;
};

export type OpenRouterModelOption = {
  label: string;
  value: string;
  note?: string | null;
  promptPricePerMillion: number;
  completionPricePerMillion: number;
  modalities: string[];
  releaseDate: string;
  contextWindow: number;
  isReasoning: boolean;
  isFree: boolean;
  isRecommended: boolean;
};

export type PermissionStatus = {
  keyboard: boolean;
  accessibility: boolean;
  screen: boolean;
};

export type LoginItemState = {
  supported: boolean;
  enabled: boolean;
  status: string;
  message: string;
};

export type SettingsOptions = {
  providers: SettingOption[];
  localModels: SettingOption[];
  openRouterModels: OpenRouterModelOption[];
  sourceLanguages: SettingOption[];
  targetLanguages: SettingOption[];
  toastPositions: SettingOption[];
};

export type SettingsState = {
  // "mas" for the sandboxed Mac App Store bundle, "direct" otherwise. The UI
  // hides the Python-backed local provider and Accessibility items on "mas".
  appVariant: "mas" | "direct";
  settings: Settings;
  defaults: Settings;
  overrides: Record<SettingField, boolean>;
  options: SettingsOptions;
  permissions: PermissionStatus;
  loginItem: LoginItemState;
  storagePath: string;
};

export type ActionResult = {
  title: string;
  message: string;
  ok: boolean;
};

export const fallbackState: SettingsState = {
  appVariant: "direct",
  settings: {
    provider: "localHyMT2",
    localModelID: "hymt2-mlx-1.8b-4bit",
    localHyMT2BackendPath: null,
    customLocalModelsPath: null,
    openRouterTextModel: "deepseek/deepseek-v4-flash",
    openRouterVisionModel: "google/gemini-3.1-flash-lite",
    openRouterModelFilter: {
      modalityMode: "textOrVision",
      minPromptPricePerMillion: 0,
      maxPromptPricePerMillion: 2,
      minCompletionPricePerMillion: 0,
      maxCompletionPricePerMillion: 10
    },
    favoriteLocalModelIDs: ["hymt2-mlx-1.8b-4bit"],
    favoriteOpenRouterModels: ["deepseek/deepseek-v4-flash"],
    includeScreenContextForLLM: false,
    sourceLanguage: "Auto",
    targetLanguage: "Korean",
    hasCompletedLocalModelSelection: false,
    toastPosition: "bottomRight",
    toastCustomPosition: null,
    toastDuration: 4
  },
  defaults: {
    provider: "localHyMT2",
    localModelID: "hymt2-mlx-1.8b-4bit",
    localHyMT2BackendPath: null,
    customLocalModelsPath: null,
    openRouterTextModel: "deepseek/deepseek-v4-flash",
    openRouterVisionModel: "google/gemini-3.1-flash-lite",
    openRouterModelFilter: {
      modalityMode: "textOrVision",
      minPromptPricePerMillion: 0,
      maxPromptPricePerMillion: 2,
      minCompletionPricePerMillion: 0,
      maxCompletionPricePerMillion: 10
    },
    favoriteLocalModelIDs: ["hymt2-mlx-1.8b-4bit"],
    favoriteOpenRouterModels: ["deepseek/deepseek-v4-flash"],
    includeScreenContextForLLM: false,
    sourceLanguage: "Auto",
    targetLanguage: "Korean",
    hasCompletedLocalModelSelection: false,
    toastPosition: "bottomRight",
    toastCustomPosition: null,
    toastDuration: 4
  },
  overrides: {
    provider: false,
    localModelID: false,
    sourceLanguage: false,
    targetLanguage: false,
    toastPosition: false,
    localHyMT2BackendPath: false,
    customLocalModelsPath: false,
    openRouterTextModel: false,
    openRouterVisionModel: false,
    openRouterModelFilter: false,
    favoriteLocalModelIDs: false,
    favoriteOpenRouterModels: false
  },
  options: {
    providers: [
      { label: "Local Model", value: "localHyMT2" },
      { label: "Apple Translation", value: "appleTranslation", note: "On-device" },
      { label: "OpenRouter LLM", value: "openRouter" }
    ],
    localModels: [
      { label: "Hy-MT2 1.8B 4-bit (MLX)", value: "hymt2-mlx-1.8b-4bit", note: "Recommended" },
      { label: "Hy-MT2 1.8B (Transformers)", value: "hymt2-transformers-1.8b" },
      { label: "Hy-MT2 30B-A3B (Transformers)", value: "hymt2-transformers-30b" },
      { label: "Hy-MT2 1.8B IQ4_XS (GGUF)", value: "hymt2-gguf-iq4-xs" },
      { label: "LFM2 Ko-En Q4_K_M (GGUF)", value: "lfm2-koen-q4-k-m" },
      { label: "NLLB CTranslate2 int8", value: "nllb-ct2-int8" },
      { label: "QuickMT En-Ko", value: "quickmt-en-ko" },
      { label: "Kanana 1.5 2.1B AIHub Ko-En LoRA", value: "kanana-lora-koen" },
      { label: "MADLAD-400 Swift int4", value: "madlad-swift-int4" }
    ],
    openRouterModels: [
      {
        label: "Google Gemini Flash Latest",
        value: "~google/gemini-flash-latest",
        promptPricePerMillion: 1.5,
        completionPricePerMillion: 9,
        modalities: ["text", "image", "video", "pdf", "audio"],
        releaseDate: "2026-04-27",
        contextWindow: 1048576,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "MiniMax-M3",
        value: "minimax/minimax-m3",
        promptPricePerMillion: 0.3,
        completionPricePerMillion: 1.2,
        modalities: ["text", "image", "video"],
        releaseDate: "2026-06-01",
        contextWindow: 524288,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Claude Opus 4.8",
        value: "anthropic/claude-opus-4.8",
        promptPricePerMillion: 5,
        completionPricePerMillion: 25,
        modalities: ["text", "image", "pdf"],
        releaseDate: "2026-05-28",
        contextWindow: 1000000,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Gemini 3.5 Flash",
        value: "google/gemini-3.5-flash",
        promptPricePerMillion: 1.5,
        completionPricePerMillion: 9,
        modalities: ["text", "image", "video", "pdf", "audio"],
        releaseDate: "2026-05-19",
        contextWindow: 1048576,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Gemini 3.1 Flash Lite",
        value: "google/gemini-3.1-flash-lite",
        promptPricePerMillion: 0.25,
        completionPricePerMillion: 1.5,
        modalities: ["text", "image", "video", "pdf", "audio"],
        releaseDate: "2026-05-07",
        contextWindow: 1048576,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "DeepSeek V4 Flash",
        value: "deepseek/deepseek-v4-flash",
        note: "Recommended",
        promptPricePerMillion: 0.0983,
        completionPricePerMillion: 0.1966,
        modalities: ["text"],
        releaseDate: "2026-04-24",
        contextWindow: 1048576,
        isReasoning: true,
        isFree: false,
        isRecommended: true
      },
      {
        label: "Anthropic Claude Sonnet Latest",
        value: "~anthropic/claude-sonnet-latest",
        promptPricePerMillion: 3,
        completionPricePerMillion: 15,
        modalities: ["text", "image", "pdf"],
        releaseDate: "2026-04-27",
        contextWindow: 1000000,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "GPT-5.5",
        value: "openai/gpt-5.5",
        promptPricePerMillion: 5,
        completionPricePerMillion: 30,
        modalities: ["pdf", "image", "text"],
        releaseDate: "2026-04-23",
        contextWindow: 1050000,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "OpenAI GPT Mini Latest",
        value: "~openai/gpt-mini-latest",
        promptPricePerMillion: 0.75,
        completionPricePerMillion: 4.5,
        modalities: ["pdf", "image", "text"],
        releaseDate: "2026-04-27",
        contextWindow: 400000,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Qwen3.7 Max",
        value: "qwen/qwen3.7-max",
        promptPricePerMillion: 1.25,
        completionPricePerMillion: 3.75,
        modalities: ["text"],
        releaseDate: "2026-05-21",
        contextWindow: 1000000,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "DeepSeek V4 Pro",
        value: "deepseek/deepseek-v4-pro",
        promptPricePerMillion: 0.435,
        completionPricePerMillion: 0.87,
        modalities: ["text"],
        releaseDate: "2026-04-24",
        contextWindow: 1048576,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Mistral Medium 3.5",
        value: "mistralai/mistral-medium-3-5",
        promptPricePerMillion: 1.5,
        completionPricePerMillion: 7.5,
        modalities: ["text", "image", "pdf"],
        releaseDate: "2026-04-30",
        contextWindow: 262144,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Kimi K2.6",
        value: "moonshotai/kimi-k2.6",
        promptPricePerMillion: 0.684,
        completionPricePerMillion: 3.42,
        modalities: ["text", "image"],
        releaseDate: "2026-04-21",
        contextWindow: 262144,
        isReasoning: true,
        isFree: false,
        isRecommended: false
      },
      {
        label: "Nemotron 3 Nano Omni (free)",
        value: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
        note: "Free",
        promptPricePerMillion: 0,
        completionPricePerMillion: 0,
        modalities: ["text", "audio", "image", "video"],
        releaseDate: "2026-04-28",
        contextWindow: 256000,
        isReasoning: true,
        isFree: true,
        isRecommended: false
      },
      {
        label: "Kimi K2.6 (free)",
        value: "moonshotai/kimi-k2.6:free",
        note: "Free",
        promptPricePerMillion: 0,
        completionPricePerMillion: 0,
        modalities: ["text", "image"],
        releaseDate: "2026-04-21",
        contextWindow: 262144,
        isReasoning: true,
        isFree: true,
        isRecommended: false
      },
      {
        label: "Owl Alpha",
        value: "openrouter/owl-alpha",
        note: "Free",
        promptPricePerMillion: 0,
        completionPricePerMillion: 0,
        modalities: ["text"],
        releaseDate: "2026-04-28",
        contextWindow: 1048756,
        isReasoning: false,
        isFree: true,
        isRecommended: false
      }
    ],
    sourceLanguages: [
      "Auto",
      "English",
      "Korean",
      "Simplified Chinese",
      "Japanese",
      "Spanish",
      "German",
      "French",
      "Indonesian",
      "Arabic"
    ].map((value) => ({ label: value, value })),
    targetLanguages: [
      "English",
      "Korean",
      "Simplified Chinese",
      "Japanese",
      "Spanish",
      "German",
      "French",
      "Indonesian",
      "Arabic"
    ].map((value) => ({ label: value, value })),
    toastPositions: [
      { label: "Bottom Right", value: "bottomRight" },
      { label: "Bottom Left", value: "bottomLeft" },
      { label: "Top Right", value: "topRight" },
      { label: "Top Left", value: "topLeft" },
      { label: "Custom", value: "custom" }
    ]
  },
  permissions: {
    keyboard: false,
    accessibility: false,
    screen: false
  },
  loginItem: {
    supported: false,
    enabled: false,
    status: "browserPreview",
    message: "Login startup is available in the installed macOS app."
  },
  storagePath: "Browser preview"
};

export function cloneFallbackState(): SettingsState {
  return structuredClone(fallbackState);
}

export type RequestLogEntry = {
  id: string;
  timestamp: string;
  source: string;
  providerTitle: string;
  model: string;
  inputPreview: string;
  outputPreview: string;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  costCredits: number | null;
  usageSource: string;
  isDuplicateSuspect: boolean;
  imageInfo: string | null;
  fingerprint: string;
};

export type RequestLogSummary = {
  requestCount: number;
  duplicateSuspectCount: number;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  costCredits: number;
};

export type RequestLogsState = {
  entries: RequestLogEntry[];
  summary: RequestLogSummary;
  storagePath: string;
};

export type BenchmarkResult = {
  output: string;
  ok: boolean;
};
