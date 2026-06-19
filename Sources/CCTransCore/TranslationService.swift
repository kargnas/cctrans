import Foundation
import Dispatch
import Darwin

public struct TranslationResult: Equatable, Sendable {
    public let text: String
    public let description: String?
    public let providerTitle: String
    public let model: String
    public let usage: TranslationUsage?
    public let sourceLanguage: String?
    public let targetLanguage: String?
    public let detectedSourceLanguage: String?
    public let imageURL: String?

    public init(
        text: String,
        description: String? = nil,
        providerTitle: String,
        model: String,
        usage: TranslationUsage? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        detectedSourceLanguage: String? = nil,
        imageURL: String? = nil
    ) {
        self.text = text
        self.description = description?.nilIfBlank
        self.providerTitle = providerTitle
        self.model = model
        self.usage = usage
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.detectedSourceLanguage = detectedSourceLanguage
        self.imageURL = imageURL?.nilIfBlank
    }
}

public struct TranslationUsage: Equatable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let costCredits: Double?

    public init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?, costCredits: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.costCredits = costCredits
    }
}

public enum TranslationError: LocalizedError, Sendable, Equatable {
    case emptyInput
    case missingCredential(String)
    case invalidURL(String)
    case invalidHTTPStatus(Int, String)
    case missingTranslation(String)
    case invalidImageData
    case localModelUnavailable(String)
    case unsupportedImageModel(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "There is no text to translate."
        case let .missingCredential(name):
            "Missing \(name). Add it to .env.local or ~/.config/cctrans/.env."
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        case let .invalidHTTPStatus(status, body):
            "Request failed with HTTP \(status): \(body)"
        case let .missingTranslation(body):
            "The model response did not contain a translation: \(body)"
        case .invalidImageData:
            "The screenshot could not be encoded."
        case let .localModelUnavailable(message):
            message
        case let .unsupportedImageModel(model):
            "\(OpenRouterModelCatalog.title(for: model)) cannot read images. Choose a Text + Image model for screenshot translation."
        }
    }
}

public final class TranslationService: @unchecked Sendable {
    private let session: URLSession
    private let localBackendGate = LocalBackendExecutionGate()
    private let appleBackend: (any AppleTranslationBacking)?
    private let openRouterModelCapabilities: @Sendable (String) -> OpenRouterModelCapabilities?

    public init(
        session: URLSession = .shared,
        appleBackend: (any AppleTranslationBacking)? = nil,
        openRouterModelCapabilities: (@Sendable (String) -> OpenRouterModelCapabilities?)? = nil
    ) {
        self.session = session
        self.appleBackend = appleBackend
        self.openRouterModelCapabilities = openRouterModelCapabilities ?? { OpenRouterModelCatalog.capabilities(for: $0) }
    }

    public func translateText(
        _ text: String,
        settings: TranslatorSettings,
        credentials: TranslatorCredentials,
        contextImagePNGData: Data? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.emptyInput
        }

        let languages = TranslationLanguageResolver.resolve(
            text: trimmed,
            sourceLanguage: settings.sourceLanguage,
            targetLanguage: settings.targetLanguage
        )

        switch settings.provider {
        case .localHyMT2:
            return try await translateWithLocalModel(
                text: trimmed,
                settings: settings,
                credentials: credentials,
                languages: languages
            )
        case .appleTranslation:
            return try await translateWithAppleTranslation(
                text: trimmed,
                languages: languages
            )
        case .openRouter:
            return try await translateWithOpenRouterText(
                text: trimmed,
                settings: settings,
                credentials: credentials,
                contextImagePNGData: contextImagePNGData,
                languages: languages,
                onPartial: onPartial
            )
        }
    }

    private func translateWithAppleTranslation(
        text: String,
        languages: ResolvedTranslationLanguages
    ) async throws -> TranslationResult {
        guard let appleBackend else {
            throw TranslationError.localModelUnavailable(
                "Apple Translation needs the running CCTrans app; this context has no translation host."
            )
        }
        // The resolver already detected the source, but an unknown name (or
        // Auto without detection) maps to nil so Apple's own detection runs.
        let sourceCode = TranslationLanguage.options
            .first { $0.name == languages.sourceLanguage }?.code
        guard let targetCode = TranslationLanguage.options
            .first(where: { $0.name == languages.targetLanguage })?.code else {
            throw TranslationError.localModelUnavailable(
                "Apple Translation does not support \(languages.targetLanguage) as a target language."
            )
        }

        let translated = try await appleBackend.translate(
            text: text,
            sourceLanguageCode: sourceCode,
            targetLanguageCode: targetCode
        )
        return TranslationResult(
            text: translated,
            providerTitle: TranslationProvider.appleTranslation.title,
            model: "apple/translation",
            sourceLanguage: languages.sourceLanguage,
            targetLanguage: languages.targetLanguage,
            detectedSourceLanguage: languages.detectedSourceLanguage
        )
    }

    public func translateImage(
        pngData: Data,
        settings: TranslatorSettings,
        credentials: TranslatorCredentials
    ) async throws -> TranslationResult {
        guard !pngData.isEmpty else {
            throw TranslationError.invalidImageData
        }
        let modelCapabilities = openRouterModelCapabilities(settings.openRouterVisionModel)
        guard modelCapabilities?.supportsVision != false else {
            throw TranslationError.unsupportedImageModel(settings.openRouterVisionModel)
        }

        let key = try require(credentials.openRouterAPIKey, named: "OPENROUTER_API_KEY")
        let wantsImageOutput = modelCapabilities?.supportsImageOutput == true
        let prompt = wantsImageOutput
            ? """
            Translate the visible text in this screenshot to \(settings.targetLanguage).

            Return an image that preserves the screenshot layout as much as possible while replacing visible text with the translation.
            If you also return text, keep it to a short summary of the rendered translation.
            """
            : """
            Screenshot text -> \(settings.targetLanguage)

            Fill the response JSON fields:
            - translation: translated visible text from the screenshot
            - description: null

            Preserve useful line breaks.
            """

        var body: [String: Any] = [
            "model": settings.openRouterVisionModel,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a precise screenshot translation engine.",
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": prompt,
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,\(pngData.base64EncodedString())",
                            ],
                        ],
                    ],
                ],
            ],
            "max_tokens": maxTokens(for: settings.openRouterVisionModel),
            "temperature": 0.1,
        ]
        if let requestedModalities = modelCapabilities?.requestedOutputModalities {
            body["modalities"] = requestedModalities
        } else {
            body["response_format"] = translationSchema
        }

        let response = try await postOpenRouter(body: body, apiKey: key)
        return TranslationResult(
            text: response.translation,
            description: response.description,
            providerTitle: TranslationProvider.openRouter.title,
            model: settings.openRouterVisionModel,
            usage: response.usage,
            imageURL: response.imageURL
        )
    }

    private func translateWithLocalModel(
        text: String,
        settings: TranslatorSettings,
        credentials: TranslatorCredentials,
        languages: ResolvedTranslationLanguages
    ) async throws -> TranslationResult {
        let model = LocalModelRegistry.model(
            id: settings.localModelID,
            customModelsPath: settings.customLocalModelsPath
        ) ?? LocalModelRegistry.defaultModel(customModelsPath: settings.customLocalModelsPath)

        guard model.supports(sourceLanguage: languages.sourceLanguage, targetLanguage: languages.targetLanguage) else {
            throw TranslationError.localModelUnavailable(
                "\(model.title) does not support \(languages.sourceLanguage) -> \(languages.targetLanguage)."
            )
        }

        let prompt = localTranslationPrompt(
            text: text,
            sourceLanguage: languages.sourceLanguage,
            targetLanguage: languages.targetLanguage
        )

        do {
            let response = try await runLocalBackend(
                prompt: prompt,
                sourceText: text,
                settings: settings,
                credentials: credentials,
                languages: languages,
                model: model
            )
            return TranslationResult(
                text: response,
                providerTitle: settings.provider.title,
                model: model.title,
                sourceLanguage: languages.sourceLanguage,
                targetLanguage: languages.targetLanguage,
                detectedSourceLanguage: languages.detectedSourceLanguage
            )
        } catch {
            throw TranslationError.localModelUnavailable("""
            Local backend failed: \(error.localizedDescription)
            """)
        }
    }

    private func translateWithOpenRouterText(
        text: String,
        settings: TranslatorSettings,
        credentials: TranslatorCredentials,
        contextImagePNGData: Data?,
        languages: ResolvedTranslationLanguages,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> TranslationResult {
        let key = try require(credentials.openRouterAPIKey, named: "OPENROUTER_API_KEY")
        // Text translation always uses the selected text model. A screen-context
        // image is only attached upstream when that model is vision-capable
        // (AppDelegate.contextImagePNGDataIfNeeded), so the chosen model handles the
        // image itself instead of silently switching to a different vision model.
        let model = settings.openRouterTextModel
        if contextImagePNGData != nil,
           openRouterModelCapabilities(model)?.supportsVision == false {
            throw TranslationError.unsupportedImageModel(model)
        }
        // Stream only the plain-text path: a copied selection with no attached screen image, and only
        // when a caller wants incremental output. Vision/disambiguation requests still use structured
        // JSON so the contextual "description" field survives. CLI/preview callers (onPartial == nil)
        // keep the blocking structured path so their description output is unchanged.
        let isStreaming = contextImagePNGData == nil && onPartial != nil
        let prompt = isStreaming
            ? openRouterPlainTextPrompt(
                text: text,
                sourceLanguage: languages.sourceLanguage,
                targetLanguage: languages.targetLanguage
            )
            : openRouterTextPrompt(
                text: text,
                sourceLanguage: languages.sourceLanguage,
                targetLanguage: languages.targetLanguage,
                hasScreenContext: contextImagePNGData != nil
            )
        let userContent: Any
        if let contextImagePNGData {
            userContent = [
                [
                    "type": "text",
                    "text": prompt,
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/png;base64,\(contextImagePNGData.base64EncodedString())",
                        "detail": "low",
                    ],
                ],
            ] as [[String: Any]]
        } else {
            userContent = prompt
        }

        let providerRouting: [String: Any] = contextImagePNGData == nil
            ? [
                "sort": "throughput",
                "preferred_max_latency": [
                    "p90": 5,
                ],
            ]
            : [
                "sort": [
                    "by": "throughput",
                    "partition": "none",
                ],
                "preferred_max_latency": [
                    "p90": 5,
                ],
            ]

        var body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a precise translation engine.",
                ],
                [
                    "role": "user",
                    "content": userContent,
                ],
            ],
            "max_tokens": maxTokens(for: model),
            "temperature": 0.1,
            "provider": providerRouting,
        ]
        if isStreaming {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        } else {
            body["response_format"] = translationSchema
        }
        let response: OpenRouterCompletion
        if isStreaming, let onPartial {
            response = try await streamOpenRouter(body: body, apiKey: key, onPartial: onPartial)
        } else {
            response = try await postOpenRouter(body: body, apiKey: key)
        }
        return TranslationResult(
            text: response.translation,
            description: response.description,
            providerTitle: settings.provider.title,
            model: model,
            usage: response.usage,
            sourceLanguage: languages.sourceLanguage,
            targetLanguage: languages.targetLanguage,
            detectedSourceLanguage: languages.detectedSourceLanguage
        )
    }

    private func runLocalBackend(
        prompt: String,
        sourceText: String,
        settings: TranslatorSettings,
        credentials: TranslatorCredentials,
        languages: ResolvedTranslationLanguages,
        model: LocalModelSpec
    ) async throws -> String {
        let backendPath = try resolveLocalBackendPath(settings: settings, model: model)
        let payload: [String: Any] = [
            "text": sourceText,
            "prompt": prompt,
            "source_language": languages.sourceLanguage,
            "target_language": languages.targetLanguage,
            "local_model_id": model.id,
            "model_id": model.modelID,
            "runtime": model.runtime.rawValue,
            "artifact_name": model.artifactName ?? "",
            "hf_token": credentials.huggingFaceToken ?? "",
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let backendGate = localBackendGate
        let processHandle = LocalBackendProcessHandle()

        let outputData = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try backendGate.waitForTurn(cancelledBy: processHandle)
                defer {
                    backendGate.releaseTurn()
                }
                try processHandle.checkCancellation()

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["uv", "run", backendPath]

                var environment = ProcessInfo.processInfo.environment
                if let token = credentials.huggingFaceToken {
                    environment["HF_TOKEN"] = token
                }
                process.environment = environment

                let input = Pipe()
                let output = Pipe()
                let error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error

                processHandle.set(process)
                defer {
                    processHandle.clear()
                }

                try process.run()
                try processHandle.checkCancellationTerminatingActiveProcess()
                input.fileHandleForWriting.write(payloadData)
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
                try processHandle.checkCancellation()

                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = error.fileHandleForReading.readDataToEndOfFile()

                guard process.terminationStatus == 0 else {
                    let stdout = String(data: data, encoding: .utf8) ?? ""
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""
                    throw TranslationError.localModelUnavailable((stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines))
                }

                return data
            }.value
        } onCancel: {
            processHandle.cancelAndTerminate()
        }

        let object = try JSONSerialization.jsonObject(with: outputData)
        guard let dictionary = object as? [String: Any] else {
            throw TranslationError.missingTranslation(String(data: outputData, encoding: .utf8) ?? "")
        }

        if let translation = dictionary["translation"] as? String {
            return cleanTranslation(translation)
        }

        if let error = dictionary["error"] as? String {
            throw TranslationError.localModelUnavailable(error)
        }

        throw TranslationError.missingTranslation(String(data: outputData, encoding: .utf8) ?? "")
    }

    private func resolveLocalBackendPath(settings: TranslatorSettings, model: LocalModelSpec) throws -> String {
        let explicit = settings.localHyMT2BackendPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }

        if let modelBackendPath = model.customBackendPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelBackendPath.isEmpty {
            return modelBackendPath
        }

        if let environmentPath = ProcessInfo.processInfo.environment["CCTRANS_LOCAL_BACKEND"],
           !environmentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentPath
        }

        if let environmentPath = ProcessInfo.processInfo.environment["CCTRANS_HYMT2_BACKEND"],
           !environmentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentPath
        }

        guard let scriptName = model.backendScriptName else {
            throw TranslationError.localModelUnavailable("\(model.title) has no bundled backend yet. Add a custom backend path or choose a bundled model.")
        }

        let candidates: [String] = [
            Bundle.main.resourceURL?.appendingPathComponent(scriptName).path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/\(scriptName)").path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Scripts/\(scriptName)").path,
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        throw TranslationError.localModelUnavailable("Could not find scripts/\(scriptName) or bundled \(scriptName).")
    }

    private func makeOpenRouterRequest(body: [String: Any], apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw TranslationError.invalidURL("https://openrouter.ai/api/v1/chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://kargn.as", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Sangrak", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func postOpenRouter(body: [String: Any], apiKey: String) async throws -> OpenRouterCompletion {
        let request = try makeOpenRouterRequest(body: body, apiKey: apiKey)
        let data = try await send(request)
        return try extractOpenRouterCompletion(from: data)
    }

    private func streamOpenRouter(
        body: [String: Any],
        apiKey: String,
        onPartial: @Sendable (String) -> Void
    ) async throws -> OpenRouterCompletion {
        var request = try makeOpenRouterRequest(body: body, apiKey: apiKey)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.missingTranslation("")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line + "\n"
            }
            throw TranslationError.invalidHTTPStatus(httpResponse.statusCode, errorBody)
        }

        var accumulated = ""
        var usage: TranslationUsage?
        // Coalesce token-level deltas to one UI push per ~120ms; the toast polls at 200ms, so finer
        // updates would be discarded and only add file-write churn.
        var lastEmit = Date.distantPast
        let emitInterval: TimeInterval = 0.12

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            else { continue }

            if object["usage"] is [String: Any] {
                usage = extractOpenRouterUsage(from: object)
            }

            guard let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty
            else { continue }

            accumulated += content
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= emitInterval {
                let partial = cleanTranslation(accumulated)
                if !partial.isEmpty {
                    lastEmit = now
                    onPartial(partial)
                }
            }
        }

        let translation = cleanTranslation(accumulated)
        guard !translation.isEmpty else {
            throw TranslationError.missingTranslation("The streamed response did not contain any text.")
        }
        onPartial(translation)
        return OpenRouterCompletion(translation: translation, description: nil, usage: usage, imageURL: nil)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.missingTranslation(String(data: data, encoding: .utf8) ?? "")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.invalidHTTPStatus(httpResponse.statusCode, body)
        }

        return data
    }

    private func extractOpenRouterCompletion(from data: Data) throws -> OpenRouterCompletion {
        let object = try JSONSerialization.jsonObject(with: data)
        guard
            let dictionary = object as? [String: Any],
            let choices = dictionary["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw TranslationError.missingTranslation(String(data: data, encoding: .utf8) ?? "")
        }

        let usage = extractOpenRouterUsage(from: dictionary)
        let content = message["content"] as? String ?? ""
        let imageURL = extractOpenRouterImageURL(from: message)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageURL != nil else {
            throw TranslationError.missingTranslation(String(data: data, encoding: .utf8) ?? "")
        }

        guard let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let translation = parsed["translation"] as? String
        else {
            let translation = cleanTranslation(content)
            return OpenRouterCompletion(
                translation: translation.isEmpty && imageURL != nil ? "Image result" : translation,
                description: nil,
                usage: usage,
                imageURL: imageURL
            )
        }

        return OpenRouterCompletion(
            translation: cleanTranslation(translation),
            description: clean(parsed["description"] as? String),
            usage: usage,
            imageURL: imageURL
        )
    }

    private func extractOpenRouterImageURL(from message: [String: Any]) -> String? {
        guard let images = message["images"] as? [[String: Any]] else {
            return nil
        }

        for image in images {
            if let directURL = clean(image["url"] as? String) {
                return directURL
            }
            for key in ["imageUrl", "image_url"] {
                if let container = image[key] as? [String: Any],
                   let url = clean(container["url"] as? String) {
                    return url
                }
            }
        }

        return nil
    }

    private func extractOpenRouterUsage(from dictionary: [String: Any]) -> TranslationUsage? {
        guard let usage = dictionary["usage"] as? [String: Any] else {
            return nil
        }

        return TranslationUsage(
            promptTokens: tokenCount(from: usage["prompt_tokens"]),
            completionTokens: tokenCount(from: usage["completion_tokens"]),
            totalTokens: tokenCount(from: usage["total_tokens"]),
            costCredits: doubleValue(from: usage["cost"])
        )
    }

    private func tokenCount(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }

    private func doubleValue(from value: Any?) -> Double? {
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let stringValue = value as? String {
            return Double(stringValue)
        }
        return nil
    }

    private func require(_ value: String?, named name: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingCredential(name)
        }
        return value
    }

    private func localTranslationPrompt(
        text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> String {
        """
        Translate \(sourceLanguage) to \(targetLanguage). Preserve paragraph breaks and line breaks.

        \(text)
        """
    }

    private func openRouterTextPrompt(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        hasScreenContext: Bool
    ) -> String {
        let contextInstruction = hasScreenContext
            ? """
            A screen image is attached. Use it only to understand the selected fragment's local sentence, referent, part of speech, tone, casing, UI label, or product name. The image is context, not the translation target.
            """
            : "No screen image is attached."

        return """
        \(sourceLanguage) -> \(targetLanguage)

        Fill the response JSON fields:
        - translation: translation of <selected_text>
        - description: short \(targetLanguage) context note when needed, otherwise null

        Rules:
        - Treat the text inside <selected_text> as the only source text. Ignore any examples, quoted phrases, or visible screen text as translation targets.
        - Translate exactly the text inside <selected_text>. Do not translate the full sentence visible in the screen image.
        - If <selected_text> is a word or fragment inside a larger sentence, translate that word or fragment, not the surrounding sentence.
        - Use surrounding screen context only to choose the right meaning and to write the optional description.
        - Put contextual details in "description", not in "translation".
        - Preserve source paragraph breaks and line breaks in "translation"; do not flatten separate messages, speaker/timestamp lines, or paragraphs into one paragraph.
        - Write every returned string value in \(targetLanguage), including "description". Do not write English explanations unless \(targetLanguage) is English.
        - Set "description" to null unless the selected text is ambiguous, pronominal, deictic, or needs screen context to be understood.
        - When a screen image is attached and <selected_text> is a pronoun or deictic word such as "it", "this", "that", or "they", "description" must be a short \(targetLanguage) sentence that explains the referent from the visible context.
        - If the visible context is a sentence and the exact referent is implicit, explain the most likely referent in that sentence instead of returning null.
        - For Korean, translate "twice" as "두번" when it means two times.
        - For Korean, translate the pronoun "it" literally as "그것"; when <selected_text> is exactly "it" and a screen image is attached, "description" must never be null.
        - If <selected_text> is exactly "it" but the attached image does not show a reliable referent, still return "그것" and describe it as the most likely object from the surrounding visible sentence.

        \(contextInstruction)

        <selected_text>
        \(text)
        </selected_text>
        """
    }

    private func openRouterPlainTextPrompt(
        text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> String {
        return """
        \(sourceLanguage) -> \(targetLanguage)
        Translate <selected_text>. Preserve paragraph breaks and line breaks.

        <selected_text>
        \(text)
        </selected_text>
        """
    }

    private func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanTranslation(_ text: String) -> String {
        var cleaned = clean(text)
        cleaned = Self.stripPromptWrapperEcho(from: cleaned)
        for instruction in Self.leakedPromptInstructions {
            cleaned = cleaned.replacingOccurrences(of: instruction, with: "")
        }
        cleaned = cleaned
            .components(separatedBy: .newlines)
            .filter { !Self.isRemovablePromptEchoLine($0) }
            .joined(separator: "\n")
        cleaned = Self.stripLeadingTranslationLabel(from: cleaned)
        return clean(cleaned)
    }

    private func clean(_ text: String?) -> String? {
        text?.nilIfBlank
    }

    private func maxTokens(for model: String) -> Int {
        let normalized = model.lowercased()
        if normalized.contains("gemini") {
            return 65_535
        }
        if normalized.contains("claude") || normalized.contains("gpt") || normalized.contains("openai") {
            return 10_000
        }
        return 10_000
    }

    private static let leakedPromptInstructions = [
        "Note that you should only output the translated result without any additional explanation:",
        "Note that you should only output the translated result without any additional explanation.",
        "Only output the translated result without any additional explanation:",
        "Only output the translated result without any additional explanation.",
        "Return only the translated text. No quotes, labels, JSON, or explanations.",
        "Return only translated text.",
        "Return only translated text",
    ]

    private static func isLeakedPromptInstructionLine(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        return leakedPromptInstructions.contains {
            normalized == $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func isRemovablePromptEchoLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["<<<", ">>>", "<selected_text>", "</selected_text>", "Text:"].contains(trimmed) {
            return true
        }
        return isLeakedPromptInstructionLine(line)
    }

    private static func stripPromptWrapperEcho(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        if let closingWrapperIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == ">>>" }) {
            let remainder = lines.dropFirst(closingWrapperIndex + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return remainder
            }
        }

        for index in lines.indices.prefix(6) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if let labelLength = leadingTranslationLabelLength(in: line) {
                let start = line.index(line.startIndex, offsetBy: labelLength)
                let sameLineRemainder = line[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                let followingRemainder = lines.dropFirst(index + 1).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return [sameLineRemainder, followingRemainder]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
        }

        return trimmed
    }

    private static func stripLeadingTranslationLabel(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let labelLength = leadingTranslationLabelLength(in: trimmed) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: labelLength)
            let remainder = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return remainder
            }
        }
        return trimmed
    }

    private static func leadingTranslationLabelLength(in text: String) -> Int? {
        let labels = [
            "Translation:",
            "Translated text:",
            "Translated result:",
            "Result:",
            "번역:",
            "번역문:",
            "번역 결과:",
            "翻訳:",
            "翻译:",
            "譯文:",
            "译文:",
        ]
        for label in labels where text.range(of: label, options: [.anchored, .caseInsensitive]) != nil {
            return label.count
        }
        return nil
    }

    private var translationSchema: [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "translation_result",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "translation": [
                            "type": "string",
                        ],
                        "description": [
                            "type": ["string", "null"],
                        ],
                    ],
                    "required": ["translation", "description"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }
}

private struct OpenRouterCompletion {
    let translation: String
    let description: String?
    let usage: TranslationUsage?
    let imageURL: String?
}

private final class LocalBackendExecutionGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func waitForTurn(cancelledBy processHandle: LocalBackendProcessHandle) throws {
        while semaphore.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            try processHandle.checkCancellation()
        }
    }

    func releaseTurn() {
        semaphore.signal()
    }
}

private final class LocalBackendProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = isCancelled
        lock.unlock()

        if shouldTerminate {
            terminate(process)
        }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancelAndTerminate() {
        lock.lock()
        isCancelled = true
        let runningProcess = process
        lock.unlock()

        guard let runningProcess else {
            return
        }
        terminate(runningProcess)
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = isCancelled
        lock.unlock()

        if isCancelled {
            throw CancellationError()
        }
    }

    func checkCancellationTerminatingActiveProcess() throws {
        lock.lock()
        let isCancelled = isCancelled
        let runningProcess = process
        lock.unlock()

        guard isCancelled else {
            return
        }

        if let runningProcess {
            terminate(runningProcess)
        }
        throw CancellationError()
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else {
            return
        }

        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.forceKillIfStillRunning(pid: pid)
        }
    }

    private func forceKillIfStillRunning(pid: pid_t) {
        lock.lock()
        let shouldKill = process?.processIdentifier == pid && process?.isRunning == true
        lock.unlock()

        if shouldKill {
            kill(pid, SIGKILL)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
