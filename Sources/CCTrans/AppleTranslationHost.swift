import AppKit
import CCTransCore
import SwiftUI
// TranslationSession is not Sendable, and the SwiftUI-inferred @MainActor
// closure makes every nonisolated async session call look like a cross-region
// send under Swift 6 strict checking. Apple's own sample drives the session
// exactly this way; preconcurrency relaxes the boundary diagnostics.
@preconcurrency import Translation

/// Bridges CCTransCore's `appleTranslation` provider to Apple's Translation
/// framework. `TranslationSession` is only handed out through SwiftUI's
/// `.translationTask` view modifier, so this host parks an invisible
/// `NSHostingView` inside the app's keep-alive window and funnels translate
/// requests through it with continuations. The session itself is not Sendable
/// and must never leave the translationTask closure; the host only hands the
/// closure Sendable work items (id + text) and receives results back.
@MainActor
final class AppleTranslationHost: ObservableObject, AppleTranslationBacking {
    static let shared = AppleTranslationHost()

    private struct Request {
        let id = UUID()
        let text: String
        let source: Locale.Language?
        let target: Locale.Language
        let continuation: CheckedContinuation<String, any Error>
    }

    @Published fileprivate var configuration: TranslationSession.Configuration?
    private var pending: [Request] = []
    private var inFlight: [UUID: Request] = [:]

    /// 1×1 transparent view carrying the `.translationTask` modifier. Must sit
    /// in an ordered-front window (the keep-alive window qualifies) or SwiftUI
    /// never schedules the task and requests would time out.
    func makeHostingView() -> NSView {
        let view = NSHostingView(rootView: AppleTranslationHostView(host: self))
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        return view
    }

    nonisolated func translate(
        text: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> String {
        let source = sourceLanguageCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: targetLanguageCode)
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.enqueue(Request(text: text, source: source, target: target, continuation: continuation))
            }
        }
    }

    private func enqueue(_ request: Request) {
        pending.append(request)
        armConfiguration(source: request.source, target: request.target)

        // A request can only hang if SwiftUI never runs the translation task
        // (host view not installed, or a language download is still pending).
        // Failing loudly beats a toast that spins forever. Only requests still
        // waiting in `pending` are timed out; in-flight ones moved to
        // `inFlight`, so a double resume cannot happen.
        let id = request.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, let index = self.pending.firstIndex(where: { $0.id == id }) else {
                return
            }
            let stale = self.pending.remove(at: index)
            stale.continuation.resume(throwing: TranslationError.localModelUnavailable(
                "Apple Translation did not start within 60s. If a language download prompt appeared, approve it and retry."
            ))
        }
    }

    private func armConfiguration(source: Locale.Language?, target: Locale.Language) {
        if var current = configuration, current.source == source, current.target == target {
            // Same pair: reassigning an equal value would not re-trigger the
            // translation task, so explicitly invalidate the session.
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    // MARK: - Queue access for the translationTask closure

    fileprivate func takeNextForActiveConfiguration() -> (id: UUID, text: String)? {
        guard let config = configuration,
              let index = pending.firstIndex(where: { $0.source == config.source && $0.target == config.target }) else {
            return nil
        }
        let request = pending.remove(at: index)
        inFlight[request.id] = request
        return (request.id, request.text)
    }

    fileprivate func complete(id: UUID, with result: Result<String, any Error>) {
        guard let request = inFlight.removeValue(forKey: id) else {
            return
        }
        request.continuation.resume(with: result)
    }

    fileprivate func failPendingForActiveConfiguration(with error: any Error) {
        guard let config = configuration else {
            return
        }
        while let index = pending.firstIndex(where: { $0.source == config.source && $0.target == config.target }) {
            pending.remove(at: index).continuation.resume(throwing: error)
        }
    }

    fileprivate func rearmForLeftoverRequests() {
        // Requests for a different language pair queued while a session ran.
        guard let next = pending.first else {
            return
        }
        armConfiguration(source: next.source, target: next.target)
    }

    /// Turns an opaque `prepareTranslation()` failure into an actionable message
    /// when the cause is a missing on-device pack. This host view is invisible,
    /// so Apple's download sheet cannot present here and prepare just throws;
    /// steer the user to the onboarding window, where the download can run.
    fileprivate func describePrepareFailure(_ error: any Error) async -> any Error {
        guard let config = configuration, let source = config.source, let target = config.target else {
            return error
        }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status != .installed else {
            return error
        }
        let name = Locale.current.localizedString(
            forLanguageCode: target.languageCode?.identifier ?? ""
        ) ?? "the selected language"
        return TranslationError.localModelUnavailable(
            "\(name) translation isn’t downloaded. Open CCTrans ▸ Getting Started… and tap Download to install it."
        )
    }
}

private struct AppleTranslationHostView: View {
    @ObservedObject var host: AppleTranslationHost

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(host.configuration) { session in
                // Downloads language assets on first use; returns immediately
                // when already installed. This view is invisible, so a missing
                // pack cannot show the system download sheet — prepare throws,
                // and we map it to an actionable error pointing at onboarding.
                do {
                    try await session.prepareTranslation()
                } catch {
                    let mapped = await host.describePrepareFailure(error)
                    await host.failPendingForActiveConfiguration(with: mapped)
                    return
                }
                while let item = await host.takeNextForActiveConfiguration() {
                    do {
                        let response = try await session.translate(item.text)
                        await host.complete(id: item.id, with: .success(response.targetText))
                    } catch {
                        await host.complete(id: item.id, with: .failure(error))
                    }
                }
                await host.rearmForLeftoverRequests()
            }
    }
}
