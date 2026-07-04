import CCTransCore
import Foundation

enum SharedOpenRouterModelCache {
    private struct CachedModel: Decodable {
        var value: String
        var modalities: [String]?
        var outputModalities: [String]?
        var maxCompletionTokens: Int?
        var contextWindow: Int?
    }

    static func capabilities(for modelID: String) -> OpenRouterModelCapabilities? {
        cachedCapabilities(for: modelID) ?? OpenRouterModelCatalog.capabilities(for: modelID)
    }

    private static func cachedCapabilities(for modelID: String) -> OpenRouterModelCapabilities? {
        let url = SharedAppStorage.fileURL("openrouter-models-cache.json")
        guard let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([CachedModel].self, from: data),
              let model = models.first(where: { $0.value == modelID }) else {
            return nil
        }

        return OpenRouterModelCapabilities(
            inputModalities: model.modalities ?? [],
            outputModalities: model.outputModalities ?? ["text"],
            maxCompletionTokens: model.maxCompletionTokens,
            contextWindow: model.contextWindow
        )
    }
}
