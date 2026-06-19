import SwiftUI
// Same rationale as AppleTranslationHost: TranslationSession is not Sendable and
// SwiftUI's @MainActor task closures trip Swift 6 region checks; preconcurrency
// relaxes the boundary diagnostics for the framework's own driving pattern.
@preconcurrency import Translation
import CCTransCore

/// Drives Apple's on-device language-pack download from a **visible** window.
///
/// Why this is separate from `AppleTranslationHost`: that host parks its
/// `.translationTask` inside a 1×1 *invisible* keep-alive window so translations
/// can run while CCTrans is a menu-bar accessory. But Apple's first-use download
/// consent is a *sheet*, and a sheet has nowhere to present from an invisible
/// window — so `prepareTranslation()` there throws instead of prompting. That is
/// exactly the "Unable to Translate" an App Reviewer hits on a machine that has
/// no Korean pack installed. This model hosts an equivalent task inside the
/// onboarding window (which IS visible and key), so the consent sheet can appear
/// and the user/reviewer can approve the download.
@MainActor
final class TranslationDownloadModel: ObservableObject {
    enum Readiness: Equatable {
        case checking
        case installed
        case needsDownload
        case downloading
        case unsupported
        case failed(String)
    }

    /// Concrete counterpart language. A pack query/download needs a non-nil
    /// source even when the user's setting is Auto, so the caller substitutes a
    /// sensible default (English, or Korean when the target itself is English).
    let source: Locale.Language
    let target: Locale.Language
    let targetDisplayName: String

    @Published var readiness: Readiness = .checking
    /// Assigning a non-nil configuration is what schedules the hosted
    /// `.translationTask`; that task calls `prepareTranslation()`, which shows
    /// the system download sheet (or returns immediately when installed).
    @Published var configuration: TranslationSession.Configuration?

    init(source: Locale.Language, target: Locale.Language, targetDisplayName: String) {
        self.source = source
        self.target = target
        self.targetDisplayName = targetDisplayName
    }

    func refresh() async {
        readiness = .checking
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: readiness = .installed
        case .supported: readiness = .needsDownload
        case .unsupported: readiness = .unsupported
        @unknown default: readiness = .needsDownload
        }
    }

    func startDownload() {
        readiness = .downloading
        // A fresh, invalidated configuration guarantees the translationTask
        // re-runs even when the same pair was requested before (e.g. a retry).
        var config = TranslationSession.Configuration(source: source, target: target)
        config.invalidate()
        configuration = config
    }

    func handleTaskFinished(error: (any Error)?) async {
        configuration = nil
        if let error {
            readiness = .failed(error.localizedDescription)
        } else {
            await refresh()
        }
    }
}

struct TranslationDownloadSection: View {
    @ObservedObject var model: TranslationDownloadModel

    var body: some View {
        GroupBox("Translation language") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).bold()
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            // Hosted here — inside the VISIBLE onboarding window — so Apple's
            // download consent sheet has a window to attach to. The invisible
            // keep-alive host cannot present it.
            .translationTask(model.configuration) { session in
                do {
                    try await session.prepareTranslation()
                    await model.handleTaskFinished(error: nil)
                } catch {
                    await model.handleTaskFinished(error: error)
                }
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.readiness {
        case .needsDownload:
            Button("Download") { model.startDownload() }
        case .failed:
            Button("Retry") { model.startDownload() }
        case .downloading:
            ProgressView().controlSize(.small)
        case .checking, .installed, .unsupported:
            EmptyView()
        }
    }

    private var title: String {
        switch model.readiness {
        case .checking: "Checking \(model.targetDisplayName)…"
        case .installed: "\(model.targetDisplayName) is ready."
        case .needsDownload: "\(model.targetDisplayName) needs a download."
        case .downloading: "Downloading \(model.targetDisplayName)…"
        case .unsupported: "\(model.targetDisplayName) is unavailable."
        case .failed: "Download failed."
        }
    }

    private var detail: String {
        switch model.readiness {
        case .checking:
            "Checking whether the on-device translation language is installed."
        case .installed:
            "On-device translation is ready to use."
        case .needsDownload:
            "Apple Translation runs offline. Tap Download to install the language once."
        case .downloading:
            "Approve the macOS download prompt if it appears."
        case .unsupported:
            "macOS has no on-device pack for this language. Pick another in Settings or use OpenRouter."
        case let .failed(message):
            message
        }
    }

    private var icon: String {
        switch model.readiness {
        case .checking, .downloading: "arrow.triangle.2.circlepath"
        case .installed: "checkmark.circle.fill"
        case .needsDownload: "arrow.down.circle.fill"
        case .unsupported: "xmark.octagon.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch model.readiness {
        case .installed: .green
        case .needsDownload, .downloading, .checking: .orange
        case .unsupported, .failed: .red
        }
    }
}
