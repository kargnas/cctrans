import CCTransCore
import Foundation
import Testing

@Test func defaultsToLocalModelAutoSourceAndKorean() {
    let settings = TranslatorSettings()

    #expect(settings.provider == .localHyMT2)
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
    #expect(settings.toastDuration == 4)
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

@Test func encodingOmitsDefaultSettings() throws {
    let data = try JSONEncoder().encode(TranslatorSettings())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object.isEmpty)
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
