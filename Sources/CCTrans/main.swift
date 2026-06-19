import AppKit
import CCTransCore

// Must run before SettingsStore/CredentialsProvider touch disk, including the
// one-shot CLI paths below.
LegacyBrandMigration.run()

func argumentValue(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else {
        return nil
    }
    let valueIndex = CommandLine.arguments.index(after: index)
    guard CommandLine.arguments.indices.contains(valueIndex) else {
        return nil
    }
    return CommandLine.arguments[valueIndex]
}

func oneShotSettings(defaultProvider: TranslationProvider) -> TranslatorSettings {
    var settings = TranslatorSettings(provider: defaultProvider)

    if let provider = argumentValue(after: "--provider") {
        switch provider {
        case "local", "local-hymt2":
            settings.provider = .localHyMT2
        case "openrouter":
            settings.provider = .openRouter
        case "apple", "apple-translation":
            settings.provider = .appleTranslation
        default:
            break
        }
    }

    if let modelID = argumentValue(after: "--local-model") {
        settings.localModelID = modelID
    }

    if let modelID = argumentValue(after: "--hy-mt2-model"),
       let model = HyMT2Model(rawValue: modelID) {
        settings.hyMT2Model = model
        settings.localModelID = LocalModelRegistry.legacyModelID(for: model)
    }

    if let backendPath = argumentValue(after: "--local-backend") {
        settings.localHyMT2BackendPath = backendPath
    }

    if let customModelsPath = argumentValue(after: "--custom-local-models") {
        settings.customLocalModelsPath = customModelsPath
    }

    if let modelID = argumentValue(after: "--openrouter-text-model") {
        settings.openRouterTextModel = modelID
    }

    if let modelID = argumentValue(after: "--openrouter-vision-model") {
        settings.openRouterVisionModel = modelID
    }

    if let language = argumentValue(after: "--target-language") {
        settings.targetLanguage = language
    }

    if let language = argumentValue(after: "--source-language") {
        settings.sourceLanguage = language
    }

    return settings
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// Emit one NDJSON line to stdout and flush immediately. The Tauri toast's retranslate path pipes this
// process's stdout and parses each line as it lands, so partials must not sit in the block buffer a
// piped (non-TTY) stdout uses — fflush forces each chunk out so the toast streams instead of waiting
// for the whole translation. JSON encoding keeps any newlines inside the text on a single line.
func emitPreviewStreamLine(_ object: [String: String]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

struct ScreenshotSmokeResult: Encodable {
    var text: String
    var model: String
    var hasImageURL: Bool
    var imageURLPrefix: String?
    var imageOutputPath: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var costCredits: Double?
}

func writeImageResult(_ imageURL: String, to outputPath: String) throws {
    let data: Data
    if let comma = imageURL.firstIndex(of: ","),
       imageURL[..<comma].lowercased().contains(";base64") {
        let encoded = String(imageURL[imageURL.index(after: comma)...])
        guard let decoded = Data(base64Encoded: encoded) else {
            throw TranslationError.missingTranslation("Image result data URL was not valid base64.")
        }
        data = decoded
    } else if let url = URL(string: imageURL), url.scheme != nil {
        data = try Data(contentsOf: url)
    } else {
        throw TranslationError.missingTranslation("Image result was not a data URL or downloadable URL.")
    }
    try data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
}

if CommandLine.arguments.contains("--login-item-status") {
    printJSON(LoginItemController.status())
    exit(0)
}

if CommandLine.arguments.contains("--set-launch-at-login") {
    let enabled = (argumentValue(after: "--set-launch-at-login") ?? "false")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    do {
        let state = try LoginItemController.setEnabled(["1", "true", "yes", "on"].contains(enabled))
        printJSON(state)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--list-local-models") {
    let settings = oneShotSettings(defaultProvider: .localHyMT2)
    let models = LocalModelRegistry.models(customModelsPath: settings.customLocalModelsPath)
    let data = try JSONEncoder().encode(models)
    print(String(data: data, encoding: .utf8) ?? "[]")
    exit(0)
}

if CommandLine.arguments.contains("--benchmark-local-models") {
    let baseSettings = oneShotSettings(defaultProvider: .localHyMT2)
    let requestedSource = argumentValue(after: "--source-language") ?? "English"
    let requestedTarget = argumentValue(after: "--target-language") ?? baseSettings.targetLanguage
    let sourceLanguage = TranslationLanguage.normalizedName(requestedSource)
    let targetLanguage = TranslationLanguage.normalizedName(requestedTarget)
    let sampleLimit = Int(argumentValue(after: "--sample-limit") ?? "") ?? 9
    let selectedModelIDs = argumentValue(after: "--local-models")?
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let models = if let selectedModelIDs, !selectedModelIDs.isEmpty {
        selectedModelIDs.compactMap { LocalModelRegistry.model(id: $0, customModelsPath: baseSettings.customLocalModelsPath) }
    } else {
        LocalModelRegistry.benchmarkModels(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            customModelsPath: baseSettings.customLocalModelsPath
        )
    }
    let samples = Array(TranslationBenchmarkSamples.samples(sourceLanguage: sourceLanguage).prefix(sampleLimit))
    let credentials = CredentialsProvider().credentials()
    let service = TranslationService(
        openRouterModelCapabilities: SharedOpenRouterModelCache.capabilities(for:)
    )

    for model in models {
        print("## \(model.title) [\(model.id)]")
        for sample in samples {
            var settings = baseSettings
            settings.provider = .localHyMT2
            settings.localModelID = model.id
            settings.sourceLanguage = sourceLanguage
            settings.targetLanguage = targetLanguage
            do {
                let result = try await service.translateText(sample.text, settings: settings, credentials: credentials)
                print("### \(sample.title)")
                print(result.text)
            } catch {
                print("### \(sample.title)")
                print("ERROR: \(error.localizedDescription)")
            }
        }
    }
    exit(0)
}

// Apple Translation sessions only exist inside a hosted SwiftUI view, so the
// one-shot path cannot stay a plain top-level await: it boots a minimal,
// invisible NSApplication around AppleTranslationHost, translates, prints, and
// exits. Used by the Tauri toast's retranslate path and as the E2E smoke.
@MainActor
func runAppleTranslationOneShot(text: String, settings: TranslatorSettings, emitPartials: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.ignoresMouseEvents = true
    window.contentView = AppleTranslationHost.shared.makeHostingView()
    window.orderFrontRegardless()

    let service = TranslationService(
        appleBackend: AppleTranslationHost.shared,
        openRouterModelCapabilities: SharedOpenRouterModelCache.capabilities(for:)
    )
    let credentials = CredentialsProvider().credentials()
    Task { @MainActor in
        do {
            let result = try await service.translateText(text, settings: settings, credentials: credentials)
            // Apple Translation has no token stream, so there are no partials — emit the result as a
            // single final line when streaming so Rust parses it the same way as the other providers.
            if emitPartials {
                emitPreviewStreamLine(["final": result.text])
            } else {
                print(result.text)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    app.run()
    fatalError("NSApplication.run returned unexpectedly")
}

if CommandLine.arguments.contains("--translate-text-once") {
    let text = argumentValue(after: "--translate-text-once") ?? ""
    let settings = oneShotSettings(defaultProvider: .localHyMT2)
    // The Tauri toast's retranslate path passes --emit-partials so it can stream the new translation
    // into the popover in place (same as the Cmd+C flow), instead of blocking until the full text is
    // ready. Without the flag, output stays byte-for-byte identical for the existing CLI/test callers.
    let emitPartials = CommandLine.arguments.contains("--emit-partials")
    if settings.provider == .appleTranslation {
        runAppleTranslationOneShot(text: text, settings: settings, emitPartials: emitPartials)
    }
    let credentials = CredentialsProvider().credentials()
    let contextImagePNGData: Data? = if CommandLine.arguments.contains("--with-screen-context") {
        try await ScreenshotCapture.captureMainDisplayContextPNG()
    } else {
        nil
    }
    // Each partial carries the cumulative text-so-far (TranslationService coalesces token deltas), so
    // forwarding it verbatim lets the toast grow the text. nil when not streaming keeps the structured
    // path (with its description field) unchanged for the plain CLI callers.
    let onPartial: (@Sendable (String) -> Void)? = emitPartials
        ? { @Sendable partial in emitPreviewStreamLine(["partial": partial]) }
        : nil
    let result = try await TranslationService(
        openRouterModelCapabilities: SharedOpenRouterModelCache.capabilities(for:)
    ).translateText(
        text,
        settings: settings,
        credentials: credentials,
        contextImagePNGData: contextImagePNGData,
        onPartial: onPartial
    )
    if emitPartials {
        emitPreviewStreamLine(["final": result.text])
    } else {
        print(result.text)
        if let description = result.description {
            print(description)
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--github-star-smoke") {
    // Headless check of the star-prompt pipeline (channel decision + gh CLI
    // availability/auth/starred state) without showing any UI.
    print(GitHubStarPrompter.smokeReport(
        hasWorkspaceRoot: CommandLine.arguments.contains("--workspace-root")
    ))
    exit(0)
}

if CommandLine.arguments.contains("--screenshot-once") {
    let settings = oneShotSettings(defaultProvider: .openRouter)
    let credentials = CredentialsProvider().credentials()
    let data = try await ScreenshotCapture.captureSelectedRegionPNG()
    let result = try await TranslationService(
        openRouterModelCapabilities: SharedOpenRouterModelCache.capabilities(for:)
    ).translateImage(pngData: data, settings: settings, credentials: credentials)
    print(result.text)
    exit(0)
}

if let imagePath = argumentValue(after: "--screenshot-image") {
    let settings = oneShotSettings(defaultProvider: .openRouter)
    let credentials = CredentialsProvider().credentials()
    let data = try Data(contentsOf: URL(fileURLWithPath: imagePath))
    let result = try await TranslationService(
        openRouterModelCapabilities: SharedOpenRouterModelCache.capabilities(for:)
    ).translateImage(pngData: data, settings: settings, credentials: credentials)
    var imageOutputPath: String?
    if let outputPath = argumentValue(after: "--output-image"),
       let imageURL = result.imageURL {
        try writeImageResult(imageURL, to: outputPath)
        imageOutputPath = outputPath
    }

    if CommandLine.arguments.contains("--json") {
        printJSON(ScreenshotSmokeResult(
            text: result.text,
            model: result.model,
            hasImageURL: result.imageURL != nil,
            imageURLPrefix: result.imageURL.map { String($0.prefix(30)) },
            imageOutputPath: imageOutputPath,
            promptTokens: result.usage?.promptTokens,
            completionTokens: result.usage?.completionTokens,
            totalTokens: result.usage?.totalTokens,
            costCredits: result.usage?.costCredits
        ))
    } else {
        print(result.text)
        if let imageURL = result.imageURL {
            print(imageURL)
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
