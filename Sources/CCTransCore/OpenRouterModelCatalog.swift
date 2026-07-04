import Foundation

public struct OpenRouterModelSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var promptPricePerMillion: Double
    public var completionPricePerMillion: Double
    public var inputModalities: [String]
    public var outputModalities: [String]
    public var releaseDate: String
    public var contextWindow: Int
    public var isReasoning: Bool
    public var isFree: Bool
    public var isRecommended: Bool

    public init(
        id: String,
        title: String,
        promptPricePerMillion: Double,
        completionPricePerMillion: Double,
        inputModalities: [String],
        outputModalities: [String] = ["text"],
        releaseDate: String,
        contextWindow: Int,
        isReasoning: Bool,
        isFree: Bool = false,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.title = title
        self.promptPricePerMillion = promptPricePerMillion
        self.completionPricePerMillion = completionPricePerMillion
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.releaseDate = releaseDate
        self.contextWindow = contextWindow
        self.isReasoning = isReasoning
        self.isFree = isFree
        self.isRecommended = isRecommended
    }

    public var supportsVision: Bool {
        inputModalities.contains("image")
    }

    public var supportsImageOutput: Bool {
        outputModalities.contains("image")
    }

    public var capabilities: OpenRouterModelCapabilities {
        OpenRouterModelCapabilities(
            inputModalities: inputModalities,
            outputModalities: outputModalities
        )
    }

    public var modalityTitle: String {
        supportsVision ? "Text + Image" : "Text"
    }

    public var pricingTitle: String {
        if isFree {
            return "Free"
        }
        return "$\(Self.formatPrice(promptPricePerMillion)) input / $\(Self.formatPrice(completionPricePerMillion)) output per 1M"
    }

    private static func formatPrice(_ value: Double) -> String {
        let formatted = String(format: value < 1 ? "%.2f" : "%.1f", value)
        var trimmed = formatted
        while trimmed.contains(".") && trimmed.last == "0" {
            trimmed.removeLast()
        }
        if trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed
    }
}

public struct OpenRouterModelCapabilities: Equatable, Sendable {
    public var inputModalities: [String]
    public var outputModalities: [String]
    // OpenRouter's `top_provider.max_completion_tokens` for this model, when known from the
    // cached models list. Used to size `max_tokens` per-model instead of a hardcoded guess
    // (see TranslationService.maxTokens(for:)). nil when the model isn't in the cache yet.
    public var maxCompletionTokens: Int?
    // The model's combined context window. Some endpoints (notably Gemini image models)
    // share one window across prompt + completion tokens rather than budgeting completion
    // separately, so this is used to clamp maxCompletionTokens when it would otherwise leave
    // no room for the prompt.
    public var contextWindow: Int?

    public init(
        inputModalities: [String],
        outputModalities: [String],
        maxCompletionTokens: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.inputModalities = Self.normalized(inputModalities)
        let output = Self.normalized(outputModalities)
        self.outputModalities = output.isEmpty ? ["text"] : output
        self.maxCompletionTokens = maxCompletionTokens
        self.contextWindow = contextWindow
    }

    public var supportsVision: Bool {
        inputModalities.contains("image")
    }

    public var supportsImageOutput: Bool {
        outputModalities.contains("image")
    }

    public var requestedOutputModalities: [String]? {
        guard supportsImageOutput else {
            return nil
        }
        if outputModalities.contains("text") {
            return ["image", "text"]
        }
        return ["image"]
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }))
            .sorted()
    }
}

public enum OpenRouterModelCatalog {
    public static let defaultModelID = TranslatorSettings.defaultOpenRouterModel

    public static let models: [OpenRouterModelSpec] = [
        OpenRouterModelSpec(
            id: "~google/gemini-flash-latest",
            title: "Google Gemini Flash Latest",
            promptPricePerMillion: 1.50,
            completionPricePerMillion: 9.00,
            inputModalities: ["text", "image", "video", "pdf", "audio"],
            releaseDate: "2026-04-27",
            contextWindow: 1_048_576,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "google/gemini-3.1-flash-lite",
            title: "Gemini 3.1 Flash Lite",
            promptPricePerMillion: 0.25,
            completionPricePerMillion: 1.50,
            inputModalities: ["text", "image", "video", "pdf", "audio"],
            releaseDate: "2026-05-07",
            contextWindow: 1_048_576,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "deepseek/deepseek-v4-flash",
            title: "DeepSeek V4 Flash",
            promptPricePerMillion: 0.0983,
            completionPricePerMillion: 0.1966,
            inputModalities: ["text"],
            releaseDate: "2026-04-24",
            contextWindow: 1_048_576,
            isReasoning: true,
            isRecommended: true
        ),
        OpenRouterModelSpec(
            id: "minimax/minimax-m3",
            title: "MiniMax-M3",
            promptPricePerMillion: 0.30,
            completionPricePerMillion: 1.20,
            inputModalities: ["text", "image", "video"],
            releaseDate: "2026-06-01",
            contextWindow: 524_288,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "anthropic/claude-opus-4.8",
            title: "Claude Opus 4.8",
            promptPricePerMillion: 5.00,
            completionPricePerMillion: 25.00,
            inputModalities: ["text", "image", "pdf"],
            releaseDate: "2026-05-28",
            contextWindow: 1_000_000,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "google/gemini-3.5-flash",
            title: "Gemini 3.5 Flash",
            promptPricePerMillion: 1.50,
            completionPricePerMillion: 9.00,
            inputModalities: ["text", "image", "video", "pdf", "audio"],
            releaseDate: "2026-05-19",
            contextWindow: 1_048_576,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "~anthropic/claude-sonnet-latest",
            title: "Anthropic Claude Sonnet Latest",
            promptPricePerMillion: 3.00,
            completionPricePerMillion: 15.00,
            inputModalities: ["text", "image", "pdf"],
            releaseDate: "2026-04-27",
            contextWindow: 1_000_000,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "openai/gpt-5.5",
            title: "GPT-5.5",
            promptPricePerMillion: 5.00,
            completionPricePerMillion: 30.00,
            inputModalities: ["pdf", "image", "text"],
            releaseDate: "2026-04-23",
            contextWindow: 1_050_000,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "~openai/gpt-mini-latest",
            title: "OpenAI GPT Mini Latest",
            promptPricePerMillion: 0.75,
            completionPricePerMillion: 4.50,
            inputModalities: ["pdf", "image", "text"],
            releaseDate: "2026-04-27",
            contextWindow: 400_000,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "qwen/qwen3.7-max",
            title: "Qwen3.7 Max",
            promptPricePerMillion: 1.25,
            completionPricePerMillion: 3.75,
            inputModalities: ["text"],
            releaseDate: "2026-05-21",
            contextWindow: 1_000_000,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "deepseek/deepseek-v4-pro",
            title: "DeepSeek V4 Pro",
            promptPricePerMillion: 0.435,
            completionPricePerMillion: 0.87,
            inputModalities: ["text"],
            releaseDate: "2026-04-24",
            contextWindow: 1_048_576,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "mistralai/mistral-medium-3-5",
            title: "Mistral Medium 3.5",
            promptPricePerMillion: 1.50,
            completionPricePerMillion: 7.50,
            inputModalities: ["text", "image", "pdf"],
            releaseDate: "2026-04-30",
            contextWindow: 262_144,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "moonshotai/kimi-k2.6",
            title: "Kimi K2.6",
            promptPricePerMillion: 0.684,
            completionPricePerMillion: 3.42,
            inputModalities: ["text", "image"],
            releaseDate: "2026-04-21",
            contextWindow: 262_144,
            isReasoning: true
        ),
        OpenRouterModelSpec(
            id: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
            title: "Nemotron 3 Nano Omni (free)",
            promptPricePerMillion: 0,
            completionPricePerMillion: 0,
            inputModalities: ["text", "audio", "image", "video"],
            releaseDate: "2026-04-28",
            contextWindow: 256_000,
            isReasoning: true,
            isFree: true
        ),
        OpenRouterModelSpec(
            id: "moonshotai/kimi-k2.6:free",
            title: "Kimi K2.6 (free)",
            promptPricePerMillion: 0,
            completionPricePerMillion: 0,
            inputModalities: ["text", "image"],
            releaseDate: "2026-04-21",
            contextWindow: 262_144,
            isReasoning: true,
            isFree: true
        ),
        OpenRouterModelSpec(
            id: "openrouter/owl-alpha",
            title: "Owl Alpha",
            promptPricePerMillion: 0,
            completionPricePerMillion: 0,
            inputModalities: ["text"],
            releaseDate: "2026-04-28",
            contextWindow: 1_048_756,
            isReasoning: false,
            isFree: true
        ),
    ]

    public static func model(id: String) -> OpenRouterModelSpec? {
        models.first { $0.id == id }
    }

    public static func capabilities(for id: String) -> OpenRouterModelCapabilities? {
        model(id: id)?.capabilities
    }

    public static func title(for id: String) -> String {
        model(id: id)?.title ?? id
    }
}
