import CCTransCore
import Foundation
import Testing

@Test func detectsKoreanAndReversesWhenTargetMatches() {
    let languages = TranslationLanguageResolver.resolve(
        text: "데이터베이스 URL이 없어서 배포가 실패했습니다.",
        sourceLanguage: TranslationLanguage.auto,
        targetLanguage: "Korean"
    )

    #expect(languages.sourceLanguage == "Korean")
    #expect(languages.targetLanguage == "English")
    #expect(languages.detectedSourceLanguage == "Korean")
    #expect(languages.didReverseBecauseLanguagesMatched)
}

@Test func keepsDifferentDetectedSourceAndTarget() {
    let languages = TranslationLanguageResolver.resolve(
        text: "The deployment failed because the database URL was missing.",
        sourceLanguage: TranslationLanguage.auto,
        targetLanguage: "Korean"
    )

    #expect(languages.sourceLanguage == "English")
    #expect(languages.targetLanguage == "Korean")
    #expect(!languages.didReverseBecauseLanguagesMatched)
}

@Test func explicitSameSourceAndTargetFallsBackToOppositeDirection() {
    let languages = TranslationLanguageResolver.resolve(
        text: "twice",
        sourceLanguage: "English",
        targetLanguage: "English"
    )

    #expect(languages.sourceLanguage == "English")
    #expect(languages.targetLanguage == "Korean")
    #expect(languages.detectedSourceLanguage == nil)
    #expect(languages.didReverseBecauseLanguagesMatched)
}

@Test func detectsEnglishWhenKoreanIsMinority() {
    let languages = TranslationLanguageResolver.resolve(
        text: "I love 김치 very much",
        sourceLanguage: TranslationLanguage.auto,
        targetLanguage: "Korean"
    )

    #expect(languages.sourceLanguage == "English")
    #expect(languages.targetLanguage == "Korean")
    #expect(languages.detectedSourceLanguage == "English")
    #expect(!languages.didReverseBecauseLanguagesMatched)
}

@Test func detectsEnglishWhenSingleKoreanCharInLongText() {
    let languages = TranslationLanguageResolver.resolve(
        text: "Hello world 김",
        sourceLanguage: TranslationLanguage.auto,
        targetLanguage: "Korean"
    )

    #expect(languages.sourceLanguage == "English")
    #expect(languages.targetLanguage == "Korean")
}

@Test func registryExposesDefaultAndBenchmarkModels() {
    let model = LocalModelRegistry.defaultModel()
    #expect(model.id == LocalModelRegistry.defaultModelID)
    #expect(model.runtime == .mlxLM)

    let benchmarkModels = LocalModelRegistry.benchmarkModels(
        sourceLanguage: "English",
        targetLanguage: "Korean"
    )
    #expect(benchmarkModels.map(\.id).contains(LocalModelRegistry.defaultModelID))
}

@Test func registryLoadsCustomModelJSON() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("cctrans-custom-model-\(UUID().uuidString).json")
    let json = """
    [
      {
        "id": "custom-ko-en",
        "title": "Custom Ko-En",
        "runtime": "custom-process",
        "modelID": "custom/model",
        "supportedSourceLanguages": ["Korean"],
        "supportedTargetLanguages": ["English"],
        "qualityNote": "test",
        "isRecommended": false,
        "includeInFirstRunBenchmark": true,
        "customBackendPath": "/tmp/custom_backend.py"
      }
    ]
    """
    try json.write(to: path, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: path)
    }

    let model = try #require(LocalModelRegistry.model(id: "custom-ko-en", customModelsPath: path.path))
    #expect(model.title == "Custom Ko-En")
    #expect(model.supports(sourceLanguage: "Korean", targetLanguage: "English"))
}

@Test func comparisonDataShowsPriorTestRecommendationAndFailures() throws {
    let recommended = LocalModelComparisonData.recommendedRow
    #expect(recommended.localModelID == LocalModelRegistry.defaultModelID)
    #expect(recommended.status == "Recommended")
    #expect(recommended.samples[.short]?.isEmpty == false)
    #expect(recommended.samples[.medium]?.isEmpty == false)
    #expect(recommended.samples[.long]?.isEmpty == false)

    let rejected = try #require(LocalModelComparisonData.rows.first { $0.id == "opus-marian-tested" })
    #expect(rejected.status == "Rejected")
    #expect(rejected.detail.contains("upstream model/tokenizer failure"))
}
