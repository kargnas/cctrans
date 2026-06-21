import Foundation

public enum TranslationProvider: String, CaseIterable, Codable, Sendable {
    case localHyMT2
    case openRouter
    // Apple's on-device Translation framework. Free, offline, and the only
    // local provider that survives App Sandbox, so it is the Mac App Store
    // build's local option (the Python-backed localHyMT2 cannot run there).
    case appleTranslation
    // kargn.as managed cloud: translate through the author's server with no
    // OpenRouter key. Anonymous device identity via App Attest (or a dev token for
    // testing). All limits/costs live server-side; the client is a thin proxy (§3).
    case kargnasManaged

    public var title: String {
        switch self {
        case .localHyMT2: "Local Model"
        case .openRouter: "OpenRouter LLM"
        case .appleTranslation: "Apple Translation"
        case .kargnasManaged: "CCTrans Cloud"
        }
    }
}

public enum HyMT2Model: String, CaseIterable, Codable, Sendable {
    case hyMT2_30B = "tencent/Hy-MT2-30B-A3B"
    case hyMT2_18B = "tencent/Hy-MT2-1.8B"

    public var title: String {
        switch self {
        case .hyMT2_30B: "Hy-MT2 30B-A3B"
        case .hyMT2_18B: "Hy-MT2 1.8B"
        }
    }

    public var temperature: Double {
        switch self {
        case .hyMT2_30B, .hyMT2_18B:
            0.7
        }
    }

    public var topP: Double {
        switch self {
        case .hyMT2_30B:
            1.0
        case .hyMT2_18B:
            0.6
        }
    }
}

public enum ToastPosition: String, CaseIterable, Codable, Sendable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
    case custom

    public var title: String {
        switch self {
        case .bottomRight: "Bottom Right"
        case .bottomLeft: "Bottom Left"
        case .topRight: "Top Right"
        case .topLeft: "Top Left"
        case .custom: "Custom"
        }
    }
}

public struct ToastCustomPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TranslatorSettings: Codable, Equatable, Sendable {
    public static let defaultOpenRouterTextModel = "deepseek/deepseek-v4-flash"
    public static let defaultOpenRouterVisionModel = "google/gemini-3.1-flash-lite"
    public static let defaultOpenRouterModel = defaultOpenRouterTextModel

    public var provider: TranslationProvider
    public var hyMT2Model: HyMT2Model
    public var localModelID: String
    public var localHyMT2BackendPath: String?
    public var customLocalModelsPath: String?
    public var openRouterTextModel: String
    public var openRouterVisionModel: String
    public var favoriteLocalModelIDs: [String]
    public var favoriteOpenRouterModels: [String]
    // Kept so older saved settings decode cleanly; the app now attaches OpenRouter screen context automatically when trusted.
    public var includeScreenContextForLLM: Bool
    public var sourceLanguage: String
    public var targetLanguage: String
    public var hasCompletedLocalModelSelection: Bool
    public var toastPosition: ToastPosition
    public var toastCustomPosition: ToastCustomPosition?
    public var toastDuration: TimeInterval
    // When true the app starts menu-bar-only (no Welcome window) on launch. Honored only
    // once required permissions are granted; a missing permission always shows the window,
    // both so the app is not silently broken and so App Review's first launch stays visible.
    public var startMenuBarOnly: Bool

    public init(
        provider: TranslationProvider = .localHyMT2,
        hyMT2Model: HyMT2Model = .hyMT2_30B,
        localModelID: String = LocalModelRegistry.defaultModelID,
        localHyMT2BackendPath: String? = nil,
        customLocalModelsPath: String? = nil,
        openRouterTextModel: String = Self.defaultOpenRouterTextModel,
        openRouterVisionModel: String = Self.defaultOpenRouterVisionModel,
        favoriteLocalModelIDs: [String] = [LocalModelRegistry.defaultModelID],
        favoriteOpenRouterModels: [String] = [Self.defaultOpenRouterTextModel],
        includeScreenContextForLLM: Bool = false,
        sourceLanguage: String = TranslationLanguage.auto,
        targetLanguage: String = "Korean",
        hasCompletedLocalModelSelection: Bool = false,
        toastPosition: ToastPosition = .bottomRight,
        toastCustomPosition: ToastCustomPosition? = nil,
        toastDuration: TimeInterval = 4,
        startMenuBarOnly: Bool = false
    ) {
        self.provider = provider
        self.hyMT2Model = hyMT2Model
        self.localModelID = localModelID
        self.localHyMT2BackendPath = localHyMT2BackendPath
        self.customLocalModelsPath = customLocalModelsPath
        self.openRouterTextModel = openRouterTextModel
        self.openRouterVisionModel = openRouterVisionModel
        self.favoriteLocalModelIDs = favoriteLocalModelIDs
        self.favoriteOpenRouterModels = favoriteOpenRouterModels
        self.includeScreenContextForLLM = includeScreenContextForLLM
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.hasCompletedLocalModelSelection = hasCompletedLocalModelSelection
        self.toastPosition = toastPosition
        self.toastCustomPosition = toastCustomPosition
        self.toastDuration = toastDuration
        self.startMenuBarOnly = startMenuBarOnly
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case hyMT2Model
        case localModelID
        case localHyMT2BackendPath
        case customLocalModelsPath
        case openRouterTextModel
        case openRouterVisionModel
        case favoriteLocalModelIDs
        case favoriteOpenRouterModels
        case includeScreenContextForLLM
        case sourceLanguage
        case targetLanguage
        case hasCompletedLocalModelSelection
        case toastPosition
        case toastCustomPosition
        case toastDuration
        case startMenuBarOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(TranslationProvider.self, forKey: .provider) ?? .localHyMT2
        let decodedHyMT2Model = try container.decodeIfPresent(HyMT2Model.self, forKey: .hyMT2Model)
        hyMT2Model = decodedHyMT2Model ?? .hyMT2_30B
        localModelID = try container.decodeIfPresent(String.self, forKey: .localModelID)
            ?? decodedHyMT2Model.map { LocalModelRegistry.legacyModelID(for: $0) }
            ?? LocalModelRegistry.defaultModelID
        localHyMT2BackendPath = try container.decodeIfPresent(String.self, forKey: .localHyMT2BackendPath)
        customLocalModelsPath = try container.decodeIfPresent(String.self, forKey: .customLocalModelsPath)
        openRouterTextModel = try container.decodeIfPresent(String.self, forKey: .openRouterTextModel) ?? Self.defaultOpenRouterTextModel
        openRouterVisionModel = try container.decodeIfPresent(String.self, forKey: .openRouterVisionModel) ?? Self.defaultOpenRouterVisionModel
        favoriteLocalModelIDs = try container.decodeIfPresent([String].self, forKey: .favoriteLocalModelIDs) ?? [LocalModelRegistry.defaultModelID]
        favoriteOpenRouterModels = try container.decodeIfPresent([String].self, forKey: .favoriteOpenRouterModels) ?? [Self.defaultOpenRouterTextModel]
        includeScreenContextForLLM = try container.decodeIfPresent(Bool.self, forKey: .includeScreenContextForLLM) ?? false
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? TranslationLanguage.auto
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "Korean"
        hasCompletedLocalModelSelection = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedLocalModelSelection) ?? false
        toastPosition = try container.decodeIfPresent(ToastPosition.self, forKey: .toastPosition) ?? .bottomRight
        toastCustomPosition = try container.decodeIfPresent(ToastCustomPosition.self, forKey: .toastCustomPosition)
        toastDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .toastDuration) ?? Self().toastDuration
        startMenuBarOnly = try container.decodeIfPresent(Bool.self, forKey: .startMenuBarOnly) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()

        // Persist only user overrides so future code default changes apply automatically.
        try container.encodeIfDifferent(provider, from: defaults.provider, forKey: .provider)
        try container.encodeIfDifferent(hyMT2Model, from: defaults.hyMT2Model, forKey: .hyMT2Model)
        try container.encodeIfDifferent(localModelID, from: defaults.localModelID, forKey: .localModelID)
        try container.encodeIfDifferent(localHyMT2BackendPath, from: defaults.localHyMT2BackendPath, forKey: .localHyMT2BackendPath)
        try container.encodeIfDifferent(customLocalModelsPath, from: defaults.customLocalModelsPath, forKey: .customLocalModelsPath)
        try container.encodeIfDifferent(openRouterTextModel, from: defaults.openRouterTextModel, forKey: .openRouterTextModel)
        try container.encodeIfDifferent(openRouterVisionModel, from: defaults.openRouterVisionModel, forKey: .openRouterVisionModel)
        try container.encodeIfDifferent(favoriteLocalModelIDs, from: defaults.favoriteLocalModelIDs, forKey: .favoriteLocalModelIDs)
        try container.encodeIfDifferent(favoriteOpenRouterModels, from: defaults.favoriteOpenRouterModels, forKey: .favoriteOpenRouterModels)
        try container.encodeIfDifferent(includeScreenContextForLLM, from: defaults.includeScreenContextForLLM, forKey: .includeScreenContextForLLM)
        try container.encodeIfDifferent(sourceLanguage, from: defaults.sourceLanguage, forKey: .sourceLanguage)
        try container.encodeIfDifferent(targetLanguage, from: defaults.targetLanguage, forKey: .targetLanguage)
        try container.encodeIfDifferent(hasCompletedLocalModelSelection, from: defaults.hasCompletedLocalModelSelection, forKey: .hasCompletedLocalModelSelection)
        try container.encodeIfDifferent(toastPosition, from: defaults.toastPosition, forKey: .toastPosition)
        try container.encodeIfDifferent(toastCustomPosition, from: defaults.toastCustomPosition, forKey: .toastCustomPosition)
        try container.encodeIfDifferent(toastDuration, from: defaults.toastDuration, forKey: .toastDuration)
        try container.encodeIfDifferent(startMenuBarOnly, from: defaults.startMenuBarOnly, forKey: .startMenuBarOnly)
    }
}

public struct TranslatorCredentials: Equatable, Sendable {
    public var openRouterAPIKey: String?
    public var huggingFaceToken: String?
    // Optional dev-bypass token for the managed (CCTrans Cloud) provider. Present only
    // for build automation / QA; signed builds use App Attest and leave this nil.
    public var cctransDevToken: String?

    public init(openRouterAPIKey: String?, huggingFaceToken: String?, cctransDevToken: String? = nil) {
        self.openRouterAPIKey = openRouterAPIKey?.nilIfBlank
        self.huggingFaceToken = huggingFaceToken?.nilIfBlank
        self.cctransDevToken = cctransDevToken?.nilIfBlank
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeIfDifferent<T: Encodable & Equatable>(_ value: T, from defaultValue: T, forKey key: Key) throws {
        guard value != defaultValue else {
            return
        }
        try encode(value, forKey: key)
    }
}
