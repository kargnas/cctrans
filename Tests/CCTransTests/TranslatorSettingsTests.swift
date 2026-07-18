import CCTransCore
import Foundation
import Testing

@Test func defaultsToManagedProviderAutoSourceAndKorean() {
    let settings = TranslatorSettings()

    // Base default is the variant-safe managed provider; the effective
    // per-variant defaults (direct=localHyMT2, mas=apple) are asserted below.
    #expect(settings.provider == .kargnasManaged)
    #expect(settings.hyMT2Model == .hyMT2_30B)
    #expect(settings.localModelID == LocalModelRegistry.defaultModelID)
    #expect(settings.openRouterTextModel == "deepseek/deepseek-v4-flash")
    #expect(settings.openRouterVisionModel == "google/gemini-3.1-flash-lite")
    #expect(settings.favoriteLocalModelIDs == [LocalModelRegistry.defaultModelID])
    #expect(settings.favoriteOpenRouterModels == ["deepseek/deepseek-v4-flash"])
    #expect(settings.includeScreenContextForLLM == false)
    #expect(settings.sourceLanguage == TranslationLanguage.auto)
    #expect(settings.targetLanguage == "Korean")
    #expect(settings.hasCompletedLocalModelSelection == false)
    #expect(settings.toastPosition == .bottomRight)
    #expect(settings.toastCustomPosition == nil)
    // Matches the Rust toast default (default_settings().toast_duration).
    #expect(settings.toastDuration == 6)
}

@Test func absentProviderKeyDecodesAsHistoricalLocalDefault() throws {
    // Wire compatibility: settings-overrides.json files written while the code
    // default was localHyMT2 omit the provider key entirely. Decoding must keep
    // resolving that absence to localHyMT2, independent of the in-memory default.
    let settings = try JSONDecoder().decode(TranslatorSettings.self, from: Data("{}".utf8))

    #expect(settings.provider == .localHyMT2)
}

@Test func decodesLegacySettingsWithScreenContextKey() throws {
    let json = """
    {
      "provider": "openRouter",
      "hyMT2Model": "tencent/Hy-MT2-1.8B",
      "openRouterTextModel": "~google/gemini-flash-latest",
      "openRouterVisionModel": "~google/gemini-flash-latest",
      "includeScreenContextForLLM": true,
      "targetLanguage": "Korean",
      "toastPosition": "bottomRight",
      "toastDuration": 6
    }
    """
    let settings = try JSONDecoder().decode(TranslatorSettings.self, from: Data(json.utf8))

    #expect(settings.provider == .openRouter)
    #expect(settings.hyMT2Model == .hyMT2_18B)
    #expect(settings.localModelID == "hymt2-transformers-1.8b")
    #expect(settings.includeScreenContextForLLM == true)
}

@Test func encodingOmitsDirectVariantDefaults() throws {
    // Direct-variant defaults are byte-identical to the wire defaults, so a
    // fresh direct install serializes to an empty overrides file.
    let data = try JSONEncoder().encode(TranslatorSettings.defaults(for: .direct))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object.isEmpty)
}

@Test func encodingWritesProviderWhenItDiffersFromWireDefault() throws {
    // The in-memory base default (kargnasManaged) differs from the wire
    // default (absent key = localHyMT2), so it must be written explicitly —
    // otherwise a reload would silently flip the provider back to local.
    let data = try JSONEncoder().encode(TranslatorSettings())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["provider"] as? String == "kargnasManaged")
    #expect(object.count == 1)
}

@Test func macAppStoreDefaultsUseAppleTranslation() {
    let settings = TranslatorSettings.defaults(for: .macAppStore)

    #expect(settings.provider == .appleTranslation)
    #expect(settings.targetLanguage == "Korean")
}

@Test func macAppStoreNormalizationKeepsUnsupportedLocalProviderOutOfHostSettings() {
    let settings = TranslatorSettings(
        provider: .localHyMT2,
        targetLanguage: "Japanese"
    )

    let normalized = settings.normalized(for: .macAppStore)

    #expect(normalized.provider == .appleTranslation)
    #expect(normalized.targetLanguage == "Japanese")
}

@Test func macAppStoreNormalizationMapsMissingProviderPayloadToAppleTranslation() throws {
    let json = #"{"targetLanguage":"Japanese"}"#
    let settings = try JSONDecoder().decode(TranslatorSettings.self, from: Data(json.utf8))

    let normalized = settings.normalized(for: .macAppStore)

    #expect(normalized.provider == .appleTranslation)
    #expect(normalized.targetLanguage == "Japanese")
}

@Test func macAppStoreNormalizationKeepsManagedProviderForCloudRevenuePath() {
    let settings = TranslatorSettings(provider: .kargnasManaged)

    let normalized = settings.normalized(for: .macAppStore)

    #expect(normalized.provider == .kargnasManaged)
}

@Test func directDefaultsAndNormalizationKeepLocalProvider() {
    let settings = TranslatorSettings.defaults(for: .direct)

    #expect(settings.provider == .localHyMT2)
    #expect(settings.normalized(for: .direct).provider == .localHyMT2)
}

@Test func encodingPersistsOnlyUserOverrides() throws {
    let settings = TranslatorSettings(
        provider: .openRouter,
        openRouterTextModel: "custom/text-model"
    )
    let data = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["provider"] as? String == "openRouter")
    #expect(object["openRouterTextModel"] as? String == "custom/text-model")
    #expect(object["openRouterVisionModel"] == nil)
    #expect(object["sourceLanguage"] == nil)
    #expect(object["targetLanguage"] == nil)
}

@Test func encodingPersistsCustomToastPositionOverride() throws {
    let settings = TranslatorSettings(
        toastPosition: .custom,
        toastCustomPosition: ToastCustomPosition(x: 128, y: 256)
    )
    let data = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let customPosition = try #require(object["toastCustomPosition"] as? [String: Any])

    #expect(object["toastPosition"] as? String == "custom")
    #expect(customPosition["x"] as? Double == 128)
    #expect(customPosition["y"] as? Double == 256)
}

@Test func explicitModelValuesAreNotMigratedOnDecode() throws {
    let json = """
    {
      "openRouterTextModel": "~google/gemini-flash-latest",
      "openRouterVisionModel": "custom/vision-model"
    }
    """
    let settings = try JSONDecoder().decode(TranslatorSettings.self, from: Data(json.utf8))

    #expect(settings.openRouterTextModel == "~google/gemini-flash-latest")
    #expect(settings.openRouterVisionModel == "custom/vision-model")
}
