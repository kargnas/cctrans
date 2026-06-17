import Foundation

public enum TranslationPreviewMetadata {
    public static func modelTitle(for result: TranslationResult, settings: TranslatorSettings) -> String {
        switch result.providerTitle {
        case TranslationProvider.openRouter.title:
            OpenRouterModelCatalog.title(for: result.model)
        case TranslationProvider.appleTranslation.title:
            "Apple Translation"
        case TranslationProvider.localHyMT2.title:
            result.model.isEmpty ? activeModelTitle(settings: settings) : result.model
        default:
            result.model.isEmpty ? activeModelTitle(settings: settings) : result.model
        }
    }

    public static func modelWarning(
        for result: TranslationResult,
        inputText: String,
        settings: TranslatorSettings
    ) -> String? {
        guard result.providerTitle == TranslationProvider.openRouter.title else {
            return nil
        }

        let usedModel = result.model
        let textModel = settings.openRouterTextModel
        guard usedModel != textModel else {
            return nil
        }

        if isScreenshotPlaceholder(inputText), usedModel == settings.openRouterVisionModel {
            if OpenRouterModelCatalog.model(id: textModel)?.supportsVision == true {
                return "Screenshot translation used the Vision Model instead of the Text Model."
            }
            return "Screenshot translation used the Vision Model because \(OpenRouterModelCatalog.title(for: textModel)) is text-only."
        }

        if settings.provider == .openRouter {
            return "Selected text model was \(OpenRouterModelCatalog.title(for: textModel)); used \(OpenRouterModelCatalog.title(for: usedModel))."
        }

        return nil
    }

    private static func activeModelTitle(settings: TranslatorSettings) -> String {
        switch settings.provider {
        case .localHyMT2:
            LocalModelRegistry.model(
                id: settings.localModelID,
                customModelsPath: settings.customLocalModelsPath
            )?.title ?? settings.localModelID
        case .openRouter:
            OpenRouterModelCatalog.title(for: settings.openRouterTextModel)
        case .appleTranslation:
            "Apple Translation"
        }
    }

    private static func isScreenshotPlaceholder(_ text: String) -> Bool {
        text == "[selected screenshot]" || text == "[screen screenshot]"
    }
}
