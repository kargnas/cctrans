import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum ScreenshotCaptureError: LocalizedError {
    case permissionDenied
    case captureFailed
    case encodingFailed
    case selectionCancelled
    case selectionInProgress
    case noRetainedScreenshot
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required for screenshot translation."
        case .captureFailed:
            "Could not capture the screenshot."
        case .noRetainedScreenshot:
            "No screenshot to translate. Capture one with ⇧⌘2 first."
        case .encodingFailed:
            "Could not encode the screenshot as PNG."
        case .selectionCancelled:
            "Screenshot selection was cancelled."
        case .selectionInProgress:
            "A screenshot selection is already in progress."
        case let .commandFailed(message):
            "The screencapture command failed: \(message)"
        }
    }
}

struct ScreenContextCaptureResult {
    let pngData: Data?
    let diagnostic: String?
}

enum ScreenshotCapture {
    static func captureMainDisplayPNG() async throws -> Data {
        try await captureMainDisplayPNG(outputScale: .point1x)
    }

    static func captureSelectedRegionPNG() async throws -> Data {
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw ScreenshotCaptureError.permissionDenied
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            try captureSelectedRegionWithSystemScreencapture()
        }.value
    }

    static func captureMainDisplayContextPNGIfAvailable() async -> ScreenContextCaptureResult {
        if CGPreflightScreenCaptureAccess() {
            do {
                let data = try await captureWithScreenCaptureKit(outputScale: .contextCrop)
                return ScreenContextCaptureResult(pngData: data, diagnostic: contextDiagnostic(prefix: "ScreenCaptureKit"))
            } catch {
                return captureContextWithScreencaptureFallback(prefix: "ScreenCaptureKit failed: \(error.localizedDescription)")
            }
        }

        // Automatic text context must never open a TCC prompt during Cmd+C.
        // In SwiftPM/VS Code dev runs, the debug executable and the .app bundle can have separate TCC identities;
        // calling /usr/sbin/screencapture here may show a prompt even when the packaged app is already approved.
        return ScreenContextCaptureResult(pngData: nil, diagnostic: "Screen Recording preflight denied; skipped automatic context capture")
    }

    static func captureMainDisplayContextPNG() async throws -> Data {
        try await captureMainDisplayPNG(outputScale: .contextCrop)
    }

    private static func captureMainDisplayPNG(outputScale: OutputScale) async throws -> Data {
        if CGPreflightScreenCaptureAccess() {
            return try await captureWithScreenCaptureKit(outputScale: outputScale)
        }

        guard CGRequestScreenCaptureAccess() else {
            throw ScreenshotCaptureError.permissionDenied
        }
        return try await captureWithScreenCaptureKit(outputScale: outputScale)
    }

    private static func captureWithScreenCaptureKit(outputScale: OutputScale) async throws -> Data {
        let content = try await shareableContent()
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw ScreenshotCaptureError.captureFailed
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true

        let configuration = SCStreamConfiguration()
        switch outputScale {
        case .native:
            configuration.width = display.width
            configuration.height = display.height
            configuration.scalesToFit = false
        case .point1x, .contextCrop:
            let bounds = CGDisplayBounds(display.displayID)
            configuration.width = max(1, Int(bounds.width.rounded()))
            configuration.height = max(1, Int(bounds.height.rounded()))
            configuration.scalesToFit = true
        }
        configuration.showsCursor = false

        let image = try await captureImage(filter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotCaptureError.encodingFailed
        }

        return data
    }

    private static func captureSelectedRegionWithSystemScreencapture() throws -> Data {
        try captureWithSystemScreencapture(
            arguments: ["-i", "-s", "-x", "-t", "png"],
            outputScale: .native,
            treatsMissingOutputAsCancellation: true
        )
    }

    private static func captureWithSystemScreencapture(outputScale: OutputScale) throws -> Data {
        try captureWithSystemScreencapture(
            arguments: ["-x", "-t", "png"],
            outputScale: outputScale,
            treatsMissingOutputAsCancellation: false
        )
    }

    private static func captureWithSystemScreencapture(
        arguments: [String],
        outputScale: OutputScale,
        treatsMissingOutputAsCancellation: Bool
    ) throws -> Data {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctrans-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [fileURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message?.localizedCaseInsensitiveContains("cannot run two interactive screen captures") == true {
                throw ScreenshotCaptureError.selectionInProgress
            }
            if treatsMissingOutputAsCancellation, message?.isEmpty != false {
                throw ScreenshotCaptureError.selectionCancelled
            }
            throw ScreenshotCaptureError.commandFailed(message ?? "exit \(process.terminationStatus)")
        }

        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            if treatsMissingOutputAsCancellation {
                throw ScreenshotCaptureError.selectionCancelled
            }
            throw ScreenshotCaptureError.captureFailed
        }
        return try resizedPNGDataIfNeeded(data, outputScale: outputScale)
    }

    private static func captureContextWithScreencaptureFallback(prefix: String) -> ScreenContextCaptureResult {
        do {
            let data = try captureWithSystemScreencapture(outputScale: .contextCrop)
            return ScreenContextCaptureResult(pngData: data, diagnostic: contextDiagnostic(prefix: "screencapture fallback"))
        } catch {
            return ScreenContextCaptureResult(
                pngData: nil,
                diagnostic: "\(prefix); screencapture fallback failed: \(error.localizedDescription)"
            )
        }
    }

    private static func resizedPNGDataIfNeeded(_ data: Data, outputScale: OutputScale) throws -> Data {
        guard outputScale == .point1x || outputScale == .contextCrop,
              let source = NSBitmapImageRep(data: data)?.cgImage else {
            return data
        }

        let bounds = CGDisplayBounds(CGMainDisplayID())
        let targetWidth = max(1, Int(bounds.width.rounded()))
        let targetHeight = max(1, Int(bounds.height.rounded()))
        let image: CGImage
        if source.width > targetWidth || source.height > targetHeight {
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ScreenshotCaptureError.encodingFailed
            }

            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let resizedImage = context.makeImage() else {
                throw ScreenshotCaptureError.encodingFailed
            }
            image = resizedImage
        } else {
            image = source
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let resized = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotCaptureError.encodingFailed
        }
        return resized
    }

    private static func contextDiagnostic(prefix: String) -> String {
        "\(prefix), full display context"
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenshotCaptureError.captureFailed)
                    return
                }

                continuation.resume(returning: content)
            }
        }
    }

    private static func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    continuation.resume(throwing: ScreenshotCaptureError.captureFailed)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    private enum OutputScale {
        case native
        case point1x
        case contextCrop
    }
}
