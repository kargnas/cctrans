import AppKit
import ApplicationServices
import CCTransCore
import CoreGraphics
import SwiftUI

// A native, main-process onboarding wizard.
//
// Why this exists: CCTrans is a menu-bar accessory app, so before this it had no
// real window at all — App Review (Guideline 2.1) repeatedly reported "does not
// launch a main window for review / unable to verify functionality." The only
// prior window surfaces were Tauri helper windows in a SEPARATE process, which
// also made the helper — not CCTrans — own any visible permission UI. Hosting
// this window in the MAIN app process fixes both:
//   1. App Review sees a window owned by CCTrans itself.
//   2. Input Monitoring / Screen Recording preflight + request run in the SAME
//      process that actually taps the keyboard, so the status shown and the
//      grant requested apply to the right TCC identity (the helper's did not).
@MainActor
final class OnboardingFlowModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case permissions, model, tryIt
        var id: Int { rawValue }
    }

    // fullFlow is first launch / menu re-entry (all three steps). permissionsOnly
    // is the post-completion re-appearance when a required grant is still missing:
    // just the permissions step with a Done button and no step indicator.
    enum Mode {
        case fullFlow
        case permissionsOnly
    }

    struct Permission: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        var granted: Bool
        let request: () -> Void
        let fallback: (() -> Void)?
    }

    @Published var step: Step = .permissions
    @Published var permissions: [Permission] = []
    @Published private var attemptedRequests: Set<String> = []
    // Mirrors settingsStore.settings.provider so the SwiftUI grid can react; the
    // store itself is not an ObservableObject.
    @Published var selectedProvider: TranslationProvider
    @Published var openRouterKeyInput: String = ""
    @Published var openRouterKeySaved: Bool = false
    @Published var openRouterKeyError: String?
    // Set when the user advances past the model step with OpenRouter selected but no
    // saved key; a one-line nudge, not a block (App Review-friendly, and they can add
    // the key in Settings).
    @Published var openRouterKeyWarning: Bool = false
    // Non-nil only while Apple Translation is the selected provider; lets step 2
    // offer a language-pack download from this visible window (the invisible
    // keep-alive host cannot present Apple's system download sheet).
    @Published private(set) var translationDownload: TranslationDownloadModel?
    // Flips true when a real translation lands while the wizard is open (step 3).
    @Published private(set) var hasTranslated = false

    let mode: Mode
    let settingsStore: SettingsStore
    let onPermissionStatusChanged: () -> Void
    let appBundleURL = Bundle.main.bundleURL
    // Set by the window controller so a SwiftUI button can close the window.
    var onDismiss: () -> Void = {}
    // hasCompletedOnboarding is written once per session (Done or window close);
    // this guards against re-writing the same override on both paths.
    private var didPersistCompletion = false

    init(
        mode: Mode,
        settingsStore: SettingsStore,
        onPermissionStatusChanged: @escaping () -> Void
    ) {
        self.mode = mode
        self.settingsStore = settingsStore
        self.selectedProvider = settingsStore.settings.provider
        self.onPermissionStatusChanged = onPermissionStatusChanged
        if settingsStore.settings.provider == .appleTranslation {
            translationDownload = Self.makeTranslationDownloadModel(settings: settingsStore.settings)
        }
        refresh()
    }

    var allGranted: Bool { permissions.allSatisfy { $0.granted } }

    // Re-read the live TCC state. Input Monitoring's preflight result is cached per
    // process, so a grant only flips to true after macOS auto-relaunches the app
    // (which it does on an Input Monitoring grant); Refresh covers Screen Recording
    // and the post-relaunch read.
    func refresh() {
        var rows: [Permission] = []
        #if !MAS_BUILD
        // Accessibility leads the list on direct builds: macOS treats it as a
        // superset of Input Monitoring (with AX granted,
        // CGPreflightListenEventAccess() reads true and a listen-only CGEventTap
        // works even with no row in the Input Monitoring pane — verified against
        // TCC.db). One AX grant therefore flips the Input row to Ready too, so
        // it is the highest-leverage first action. Both cards are compile-gated
        // off the MAS build (App Review 2.4.5): no AX symbol may link there, and
        // ⌘C detection runs permission-free through PasteboardMonitor.
        rows.append(Permission(
            id: "ax",
            symbol: "accessibility",
            title: "Accessibility",
            detail: attemptedRequests.contains("ax")
                ? "If no macOS prompt appeared, enable CCTrans in Accessibility settings."
                : "Reads the text selection and unlocks keyboard detection — grant this one first.",
            granted: AXIsProcessTrusted(),
            request: { [weak self] in self?.requestAccessibilityAccess() },
            fallback: { Self.openPrivacySettings("Privacy_Accessibility") }
        ))
        // OR with AX: CGPreflight's per-process cache can lag a fresh AX grant,
        // but keyboard detection already works then (listen tap via AX, or the
        // NSEvent-monitor fallback) — so an AX grant flips this row to Ready
        // immediately instead of waiting for a relaunch.
        let inputGranted = CGPreflightListenEventAccess() || AXIsProcessTrusted()
        let inputViaAccessibility = inputGranted && AXIsProcessTrusted()
        rows.append(Permission(
            id: "input",
            symbol: "keyboard",
            title: "Input Monitoring",
            detail: inputViaAccessibility
                ? "Covered by the Accessibility permission — CCTrans may not appear in the Input Monitoring list."
                : attemptedRequests.contains("input")
                    ? "Enable CCTrans in Input Monitoring settings; macOS relaunches the app after granting."
                    : "Detects the double ⌘C that triggers a translation.",
            granted: inputGranted,
            request: { [weak self] in self?.requestInputMonitoringAccess() },
            fallback: { Self.openPrivacySettings("Privacy_ListenEvent") }
        ))
        #endif
        rows.append(Permission(
            id: "screen",
            symbol: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            detail: attemptedRequests.contains("screen")
                ? "If no macOS prompt appeared, enable CCTrans in Screen Recording settings."
                : "Captures the selected region for screenshot translation.",
            granted: CGPreflightScreenCaptureAccess(),
            request: { [weak self] in self?.requestScreenRecordingAccess() },
            fallback: { Self.openPrivacySettings("Privacy_ScreenCapture") }
        ))
        // The window controller re-runs this on app activation and on a timer, so
        // skip the publish (and the cache write) when nothing actually changed —
        // the shared-dir cache write would otherwise wake the settings watchers
        // every 2 seconds.
        let signature = rows.map { "\($0.id)|\($0.granted)|\($0.detail)" }
        guard signature != permissions.map({ "\($0.id)|\($0.granted)|\($0.detail)" }) else { return }
        permissions = rows
        onPermissionStatusChanged()
    }

    func revealAppBundle() {
        NSWorkspace.shared.activateFileViewerSelecting([appBundleURL])
    }

    func selectProvider(_ provider: TranslationProvider) {
        selectedProvider = provider
        settingsStore.settings.provider = provider
        // Build the Apple language-pack download model lazily, only once Apple
        // Translation is actually chosen (it queries LanguageAvailability).
        if provider == .appleTranslation, translationDownload == nil {
            translationDownload = Self.makeTranslationDownloadModel(settings: settingsStore.settings)
        }
    }

    func saveOpenRouterKey() {
        let trimmed = openRouterKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try OpenRouterKeyStore.write(trimmed)
            openRouterKeySaved = true
            openRouterKeyError = nil
            openRouterKeyWarning = false
        } catch {
            // Surface the failure instead of silently dropping the key.
            openRouterKeySaved = false
            openRouterKeyError = error.localizedDescription
        }
    }

    // Records the "you skipped the key" nudge when leaving the model step; still
    // returns so the caller advances regardless.
    func flagOpenRouterKeyIfMissing() {
        if selectedProvider == .openRouter, !openRouterKeySaved {
            openRouterKeyWarning = true
        }
    }

    // Called by AppDelegate when a real translation result is shown. Only the
    // full flow has a Try It step, and the celebration runs once.
    func noteTranslationSucceeded() {
        guard mode == .fullFlow, !hasTranslated else { return }
        hasTranslated = true
    }

    func persistCompletionIfNeeded() {
        guard !didPersistCompletion else { return }
        didPersistCompletion = true
        // SettingsStore persists on assignment (didSet); a no-op assignment when
        // already true is harmless.
        if !settingsStore.settings.hasCompletedOnboarding {
            settingsStore.settings.hasCompletedOnboarding = true
        }
    }

    /// The in-window sample sentence for step 3. Needs a source language that
    /// differs from the target, so translating INTO English shows a Korean line.
    var trySampleText: String {
        let target = TranslationLanguage.normalizedName(settingsStore.settings.targetLanguage)
        if target == "English" {
            return "빠른 갈색 여우가 게으른 개를 뛰어넘는다."
        }
        return "The quick brown fox jumps over the lazy dog."
    }

    // Grants that land after these requests (dialog, Settings toggle) are picked
    // up by the window controller's activation observer + 2s poll — no extra
    // delayed refresh needed here.
    private func requestScreenRecordingAccess() {
        attemptedRequests.insert("screen")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
        if !CGPreflightScreenCaptureAccess() {
            Self.openPrivacySettings("Privacy_ScreenCapture")
        }
    }

    #if !MAS_BUILD
    private func requestInputMonitoringAccess() {
        attemptedRequests.insert("input")
        // The OS prompt appears only on the very first ask; after a denial macOS
        // never re-prompts, so Settings is opened as well when the preflight
        // still reads false. A grant makes macOS auto-relaunch the app, which is
        // when the per-process preflight cache finally flips to true.
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        refresh()
        if !CGPreflightListenEventAccess() {
            Self.openPrivacySettings("Privacy_ListenEvent")
        }
    }

    private func requestAccessibilityAccess() {
        attemptedRequests.insert("ax")
        // The prompt option shows the OS dialog only once per TCC state; the
        // fallback link opens Settings directly for the re-ask case.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
    #endif

    // Moved here from AppDelegate: the download model is created at provider-
    // selection time now, not at window construction, so switching to Apple
    // Translation inside the wizard wires it up immediately.
    private static func makeTranslationDownloadModel(settings: TranslatorSettings) -> TranslationDownloadModel? {
        let targetName = TranslationLanguage.normalizedName(settings.targetLanguage)
        guard let targetCode = TranslationLanguage.options
            .first(where: { $0.name == targetName })?.code else { return nil }
        let sourceCode = TranslationLanguage.options
            .first(where: { $0.name == TranslationLanguage.normalizedName(settings.sourceLanguage) })?.code
        // A pack query needs a concrete counterpart; Auto has no code, so assume
        // English (or Korean when the target itself is English).
        let counterpart = sourceCode ?? (targetCode == "en" ? "ko" : "en")
        return TranslationDownloadModel(
            source: Locale.Language(identifier: counterpart),
            target: Locale.Language(identifier: targetCode),
            targetDisplayName: targetName
        )
    }

    // Internal: also the recovery path for the Tauri "screen" permission action
    // in AppDelegate, so every Privacy pane open goes through one place.
    static func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
        // macOS frequently does NOT auto-add the app to the opened Privacy list,
        // and System Settings now covers the wizard — float a draggable app chip
        // next to the Settings window so the drop is possible right there. The
        // chip self-dismisses once the matching grant lands.
        PrivacyDragOverlayController.shared.show(
            appBundleURL: Bundle.main.bundleURL,
            isSatisfied: satisfiedCheck(for: anchor)
        )
    }

    private static func satisfiedCheck(for anchor: String) -> () -> Bool {
        switch anchor {
        case "Privacy_ScreenCapture":
            return { CGPreflightScreenCaptureAccess() }
        #if !MAS_BUILD
        // Input/AX panes are only ever opened on direct builds (their permission
        // cards are compiled out on MAS, where these APIs must not link).
        case "Privacy_ListenEvent":
            // AX satisfies keyboard listening too, and CGPreflight's per-process
            // cache can stay false right after a grant — without the OR the chip
            // would outlive a grant that already works.
            return { CGPreflightListenEventAccess() || AXIsProcessTrusted() }
        case "Privacy_Accessibility":
            return { AXIsProcessTrusted() }
        #endif
        default:
            return { false }
        }
    }
}

// MARK: - Root shell

struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingFlowModel

    var body: some View {
        HStack(spacing: 0) {
            OnboardingLeftPane(model: model)
                .frame(width: 420)
            OnboardingPreviewStage(model: model)
                .frame(width: 340)
        }
        .frame(width: 760, height: 520)
    }
}

private struct OnboardingLeftPane: View {
    @ObservedObject var model: OnboardingFlowModel
    // Drives the slide direction of the step transition: Next slides new content
    // in from the trailing edge, Back mirrors it from the leading edge.
    @State private var isForward = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.mode == .fullFlow {
                StepIndicator(current: model.step)
            }

            // Keyed on the step so a change is an insert+removal pair SwiftUI can
            // slide; the spring is Apple's critically damped "move" preset (no bounce).
            ZStack(alignment: .topLeading) {
                stepBody
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .permissions: PermissionsStepView(model: model)
        case .model: ModelStepView(model: model)
        case .tryIt: TryItStepView(model: model)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Priming context: never force a grant (App Review 5.1.1) — say the
            // permissions can wait so Next reads as safe.
            if model.mode == .fullFlow, model.step == .permissions, !model.allGranted {
                Text("You can grant these later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if canGoBack {
                    Button("Back") { goBack() }
                }
                Spacer()
                primaryButton
            }
        }
    }

    private var canGoBack: Bool {
        model.mode == .fullFlow && model.step != .permissions
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.mode == .permissionsOnly {
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
        } else if model.step == .tryIt {
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Next") { goNext() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func goNext() {
        if model.step == .model {
            model.flagOpenRouterKeyIfMissing()
        }
        guard let next = OnboardingFlowModel.Step(rawValue: model.step.rawValue + 1) else { return }
        isForward = true
        withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) {
            model.step = next
        }
    }

    private func goBack() {
        guard let previous = OnboardingFlowModel.Step(rawValue: model.step.rawValue - 1) else { return }
        isForward = false
        withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) {
            model.step = previous
        }
    }

    private func finish() {
        model.persistCompletionIfNeeded()
        model.onDismiss()
    }
}

private struct StepIndicator: View {
    let current: OnboardingFlowModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingFlowModel.Step.allCases) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)
            }
        }
    }
}

// MARK: - Window controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var flowModel: OnboardingFlowModel?
    private var activationObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var appIsTerminating = false

    // Granting Screen Recording / Input Monitoring makes macOS quit & reopen the
    // whole app, killing this window mid-wizard. The marker is written while the
    // window is open and cleared only on a USER close (Done, traffic light) — so
    // after any process death with the wizard up (TCC relaunch, SIGKILL), the next
    // launch sees the marker and brings the window straight back. A separate
    // helper process cannot solve this instead: TCC preflight/request only mean
    // anything in the process that taps the keyboard, and that process must die
    // for the grant to apply anyway.
    private static let resumeMarkerURL = SharedAppStorage.fileURL("onboarding-resume")

    static var hasResumeMarker: Bool {
        FileManager.default.fileExists(atPath: resumeMarkerURL.path)
    }

    private static func writeResumeMarker() {
        try? SharedAppStorage.ensureDirectoryExists()
        try? Data().write(to: resumeMarkerURL)
    }

    private static func clearResumeMarker() {
        try? FileManager.default.removeItem(at: resumeMarkerURL)
    }

    // Called from applicationShouldTerminate: the imminent window close is the
    // app quitting (TCC's Quit & Reopen), not the user finishing the wizard.
    func noteAppTerminating() {
        appIsTerminating = true
    }

    func show(flowModel: OnboardingFlowModel) {
        self.flowModel = flowModel
        flowModel.onDismiss = { [weak self] in self?.window?.close() }
        flowModel.refresh()
        startLivePermissionRefresh()
        Self.writeResumeMarker()

        let hosting = NSHostingController(rootView: OnboardingRootView(model: flowModel))
        if let window {
            // Reused across reopens; just swap in a fresh root for the new session.
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to CCTrans"
            // Titled + closable only: the wizard is a fixed 760×520 canvas, so it is
            // not resizable and not miniaturizable.
            window.styleMask = [.titled, .closable]
            // Reused across reopens, so it must survive being closed.
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 760, height: 520))
            window.center()
            self.window = window
        }
        // An LSUIElement/accessory app has no Dock icon; without an explicit
        // activate the window can open behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopLivePermissionRefresh()
        // A close during app termination is TCC's Quit & Reopen, not the user
        // finishing: keep the resume marker (and don't mark onboarding complete)
        // so the relaunch reopens the wizard where the grant flow left off.
        guard !appIsTerminating else { return }
        Self.clearResumeMarker()
        // Closing the wizard (traffic light, Cmd+W) counts as finishing it, matching
        // the Done button so a completed run is not re-shown on the next launch.
        flowModel?.persistCompletionIfNeeded()
    }

    // Grants happen OUTSIDE this app (System Settings toggles, OS dialogs), so the
    // pills go stale the moment the user leaves. Re-read on every app activation —
    // the "came back from System Settings" moment — plus a slow poll while visible,
    // because a Settings toggle also lands without any activation change when the
    // wizard stays frontmost on another display. refresh() self-deduplicates, so
    // both signals are cheap no-ops when nothing changed.
    private func startLivePermissionRefresh() {
        stopLivePermissionRefresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flowModel?.refresh() }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flowModel?.refresh() }
        }
        // .common keeps the poll alive while SwiftUI runs its interaction modes.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopLivePermissionRefresh() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
