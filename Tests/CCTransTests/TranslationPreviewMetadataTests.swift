import CCTransCore
import Testing

struct TranslationPreviewMetadataTests {
    @Test func screenshotResultDisplaysVisionModelAndWarnsWhenTextModelDiffers() {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "deepseek/deepseek-v4-flash",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let result = TranslationResult(
            text: "번역",
            providerTitle: TranslationProvider.openRouter.title,
            model: "google/gemini-3.1-flash-lite"
        )

        #expect(TranslationPreviewMetadata.modelTitle(for: result, settings: settings) == "Gemini 3.1 Flash Lite")
        #expect(
            TranslationPreviewMetadata.modelWarning(
                for: result,
                inputText: "[selected screenshot]",
                settings: settings
            ) == "Screenshot translation used the Vision Fallback Model because DeepSeek V4 Flash is text-only."
        )
    }

    @Test func textResultHasNoWarningWhenSelectedTextModelWasUsed() {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "deepseek/deepseek-v4-flash",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let result = TranslationResult(
            text: "번역",
            providerTitle: TranslationProvider.openRouter.title,
            model: "deepseek/deepseek-v4-flash"
        )

        #expect(TranslationPreviewMetadata.modelTitle(for: result, settings: settings) == "DeepSeek V4 Flash")
        #expect(
            TranslationPreviewMetadata.modelWarning(
                for: result,
                inputText: "hello",
                settings: settings
            ) == nil
        )
    }
}
