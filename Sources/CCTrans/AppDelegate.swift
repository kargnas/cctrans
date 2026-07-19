import AppKit
import CCTransCore
import CoreGraphics
#if !MAS_BUILD
// The Mac App Store build must not contain Sparkle: the store owns updates and
// App Review rejects bundled self-updaters. Package.swift drops the dependency
// when CCTRANS_MAS_BUILD=1.
import Sparkle
#endif
import UserNotifications

struct TranslationPreviewPayload: Encodable {
    var mode: String
    var sourceLanguage: String
    var targetLanguage: String
    var didReverseBecauseLanguagesMatched: Bool = false
    var originalText: String
    var translatedText: String
    var translatedImageURL: String? = nil
    var errorText: String?
    var providerTitle: String
    var model: String
    var modelWarning: String? = nil
    var costCredits: Double?
    var permissionAction: String? = nil
    var requestSequence: Int = 0
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let onboardingProgressStore = OnboardingProgressStore(
        fileURL: SharedAppStorage.fileURL("onboarding-progress.json")
    )
    private let credentialsProvider = CredentialsProvider()
    private lazy var accountClient = CctransAccountClient(
        sessionCoordinator: CctransAccountStorage.sessionCoordinator,
        attestor: CctransAppAttestor.shared,
        devTokenProvider: { CredentialsProvider().credentials().cctransDevToken },
        appTransactionProvider: { await CctransAppTransactionProvider.shared.signedAppTransaction() },
        appReceiptProvider: { await CctransAppTransactionProvider.shared.appStoreReceipt() }
    )
    private let appleSignIn = CctransAppleSignIn()
    private let translationService = TranslationService(
        appleBackend: AppleTranslationHost.shared,
        // CCTrans Cloud client. MAS prefers the signed StoreKit AppTransaction and
        // falls back to the local App Store receipt because macOS TestFlight can
        // fail AppTransaction.shared before public distribution; direct/dev builds
        // use App Attest when available or an optional dev token from CredentialsProvider.
        managedClient: CctransManagedClient(
            attestor: CctransAppAttestor.shared,
            appTransactionProvider: { await CctransAppTransactionProvider.shared.signedAppTransaction() },
            appReceiptProvider: { await CctransAppTransactionProvider.shared.appStoreReceipt() },
            bearerTokenProvider: {
                try CctransAccountStorage.sessionCoordinator.loadToken()
            },
            invalidBearerHandler: { token in
                try CctransAccountStorage.sessionCoordinator.clearIfTokenMatches(token)
            }
        ),
        openRouterModelCapabilities: SharedOpenRouterModelCache.capabilities(for:)
    )
    private let requestLogStore = RequestLogStore()
    private let localModelWarmupNotifier = LocalModelWarmupNotifier()
    private var statusItem: NSStatusItem?
    // Only the direct-distribution build observes the keyboard; the MAS build relies on
    // PasteboardMonitor instead (no Input Monitoring — App Review 2.4.5).
    #if !MAS_BUILD
    private var keyboardMonitor: KeyboardMonitor?
    #endif
    private var pasteboardMonitor: PasteboardMonitor?
    private var screenshotHotKey: ScreenshotHotKey?
    private var keepAliveWindow: NSWindow?
    private var onboardingController: OnboardingWindowController?
    private var statusPulseTask: Task<Void, Never>?
    private var lastClipboardTriggerAt: Date?
    private var translationRequestSequence = 0
    private var lastPartialWriteAt = Date.distantPast
    private var lastPartialTranslatedLength = 0
    private var currentTextTranslationTask: Task<Void, Never>?
    private var currentScreenshotTranslationTask: Task<Void, Never>?
    private var isScreenshotSelectionActive = false
    private var didRegisterScreenshotHotKey = false
    private var currentTextTranslationUsesLocalBackend = false
    private var lastReadyLocalModelID: String?
    private var hasStarted = false
    private var permissionStatusTimer: Timer?
    private var permissionRequestWatcher: DispatchSourceFileSystemObject?
    private var accountRequestWatcher: DispatchSourceFileSystemObject?
    private var accountRequestTask: Task<Void, Never>?
    // Last status written to permission-status.json; only rewrite the shared file
    // when a grant actually flips, so the steady-state poll never churns the shared
    // directory watchers (SettingsStore / the Tauri helper) every tick.
    private var lastWrittenPermissionStatus: [String: Bool]?
    private var lifetimeActivity: NSObjectProtocol?
    #if MAS_BUILD
    // Login-item registration must run in THIS process. SMAppService.mainApp
    // registers Bundle.main, and only the outer CCTrans.app host resolves
    // Bundle.main to the outer bundle. Under App Sandbox the Tauri toast's own
    // Bundle.main is the inner CCTransTauri.app, so it cannot register the outer
    // app itself; it drops a request file in the shared app-group dir and this
    // watcher serves it. See serveLoginRequests() / src-tauri request_login_item().
    private var loginRequestWatcher: DispatchSourceFileSystemObject?
    // The toast's "Translate Screenshot" action drops a trigger file here; the host
    // runs the capture as the outer app (correct Screen Recording attribution).
    private var screenshotRequestWatcher: DispatchSourceFileSystemObject?
    #endif
    #if !MAS_BUILD
    // Sparkle needs a strong reference for the whole app lifetime; menu-bar apps
    // must keep this in AppDelegate, not in a transient controller.
    private var updaterController: SPUStandardUpdaterController?
    #endif
    private let githubStarPrompter = GitHubStarPrompter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        recoverCompletedOnboardingIfNeeded()

        lifetimeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "CCTrans must keep monitoring clipboard and shortcuts without a regular window."
        )
        ProcessInfo.processInfo.disableAutomaticTermination("CCTrans must keep monitoring clipboard and shortcuts without a regular window.")
        NSApp.setActivationPolicy(.accessory)
        startUpdaterIfBundled()
        configureMainMenu()
        createKeepAliveWindow()
        // The Tauri toast writes the global target language to the shared override
        // file; rebuild the menu when that happens so both surfaces stay in sync.
        settingsStore.onExternalChange = { [weak self] in
            self?.rebuildMenu()
        }
        #if MAS_BUILD
        // Serve "Open at Login" toggles from the sandboxed toast here, so
        // SMAppService registers the outer CCTrans.app rather than the inner helper.
        startLoginRequestWatcher()
        // Route the toast's screenshot-translate action to THIS process so the
        // capture is attributed to the outer CCTrans.app, not the inner helper.
        startScreenshotRequestWatcher()
        // Seed the status cache before the toast can read it, so its first
        // settings load is a plain file read, not an IPC round-trip.
        writeLoginStateCache(LoginItemController.status())
        #endif
        configureStatusItem()
        localModelWarmupNotifier.requestAuthorization()
        startScreenshotHotKey()
        #if !MAS_BUILD
        startKeyboardMonitor()
        #endif
        startPasteboardMonitor()
        resetPersistedToastSequence()
        // Clear any persistent toast helper orphaned by a previous main process
        // that exited without cleanup (e.g. a crash). Otherwise each relaunch
        // stacks another helper, and an orphaned helper lingers as a zombie that
        // owns no menu-bar item — exactly the "no icon, nothing happens" state.
        terminateTauriHelper(matching: "--translation-preview")
        startPersistentToastProcess()
        print("CCTrans ready. Press Cmd+C twice to translate clipboard text.")
        reportKeyboardPermissionStatus(requestIfMissing: false)
        // Publish our (the outer app's) real permission state for the helper UI,
        // then keep it current — the helper runs in a different bundle and cannot
        // read our TCC grants itself.
        writePermissionStatusCache()
        startPermissionRequestWatcher()
        startAccountRequestWatcher()
        startPermissionStatusTimer()
        githubStarPrompter.scheduleIfEligible(
            hasWorkspaceRoot: resolveWorkspaceRootURL() != nil,
            hasCompletedInitialSetup: settingsStore.settings.hasCompletedLocalModelSelection
        )
        let runsPopoverSmoke = CommandLine.arguments.contains("--show-popover-smoke")
        if CommandLine.arguments.contains("--show-settings") {
            showSettingsWindow()
        }
        if CommandLine.arguments.contains("--show-onboarding") {
            showOnboardingWindow()
        }
        if CommandLine.arguments.contains("--show-permission-helper") {
            showPermissionHelper()
        }
        if CommandLine.arguments.contains("--show-local-model-setup") {
            showLocalModelSetup()
        }
        if CommandLine.arguments.contains("--show-request-logs") {
            showRequestLogs()
        }
        if runsPopoverSmoke {
            showTranslationPopoverSmoke()
        }
        if !runsPopoverSmoke, !CommandLine.arguments.contains("--show-permission-helper") {
            showOnboardingOnLaunchIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Do not veto system-driven termination. macOS TCC asks to quit/reopen
        // after Screen Recording changes; canceling here leaves the grant stale.
        .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An accessory app has no Dock icon, so a Finder / Launchpad / TestFlight
        // "Open" on the already-running instance would otherwise do nothing visible.
        // Surface the useful window (Settings when ready, Welcome when a grant is
        // missing) so reopening never appears dead.
        surfaceLaunchWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The persistent toast process has no Dock icon and survives window hide, so it would
        // linger as a zombie unless the menu-bar app kills it explicitly on quit.
        terminateTauriHelper(matching: "--translation-preview")
        permissionStatusTimer?.invalidate()
        permissionRequestWatcher?.cancel()
        accountRequestWatcher?.cancel()
        accountRequestTask?.cancel()
        #if MAS_BUILD
        loginRequestWatcher?.cancel()
        screenshotRequestWatcher?.cancel()
        #endif
    }

    private static var accountRequestsDirectoryURL: URL {
        SharedAppStorage.directoryURL.appendingPathComponent("account-requests", isDirectory: true)
    }

    private func startAccountRequestWatcher() {
        let directoryURL = AppDelegate.accountRequestsDirectoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        serveAccountRequests()
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.serveAccountRequests()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        accountRequestWatcher = source
    }

    private func serveAccountRequests() {
        guard accountRequestTask == nil else { return }
        accountRequestTask = Task { [weak self] in
            guard let self else { return }
            let directoryURL = AppDelegate.accountRequestsDirectoryURL
            let dispatcher = accountRequestDispatcher()
            while !Task.isCancelled {
                let requests = (try? CctransAccountRequestFiles.pendingRequests(in: directoryURL)) ?? []
                guard let request = requests.first else {
                    break
                }
                let response = await dispatcher.response(for: request.action)
                do {
                    try CctransAccountRequestFiles.complete(request, with: response, in: directoryURL)
                } catch {
                    try? FileManager.default.removeItem(at: request.requestURL)
                }
            }
            accountRequestTask = nil
            if (try? CctransAccountRequestFiles.pendingRequests(in: directoryURL).isEmpty) == false {
                serveAccountRequests()
            }
        }
    }

    private func accountRequestDispatcher() -> CctransAccountRequestDispatcher {
        CctransAccountRequestDispatcher(
            appleLogin: { [weak self] in
                guard let self else {
                    return .error(title: "Apple Sign In", message: "CCTrans is shutting down.")
                }
                do {
                    let credential = try await appleSignIn.authorize()
                    let session = try await accountClient.signInWithApple(
                        identityToken: credential.identityToken,
                        nonce: credential.nonce,
                        name: credential.name
                    )
                    return .success(
                        title: "Apple Sign In",
                        message: "Signed in as \(session.account.email)."
                    )
                } catch {
                    return .error(title: "Apple Sign In", message: error.localizedDescription)
                }
            },
            logout: { [weak self] in
                guard let self else {
                    return .error(title: "Logout", message: "CCTrans is shutting down.")
                }
                do {
                    try await accountClient.logout()
                    return .success(title: "Logout", message: "Signed out on this Mac.")
                } catch {
                    do {
                        guard try CctransAccountStorage.sessionCoordinator.loadToken() != nil else {
                            return .success(
                                title: "Logout",
                                message: "Signed out on this Mac. The server could not be reached."
                            )
                        }
                    } catch {
                        return .error(title: "Logout", message: error.localizedDescription)
                    }
                    return .error(title: "Logout", message: error.localizedDescription)
                }
            },
            refresh: { [weak self] in
                guard let self else {
                    return .error(title: "Account Refresh", message: "CCTrans is shutting down.")
                }
                do {
                    let account = try await accountClient.refresh()
                    return account.map {
                        .success(title: "Account Refresh", message: "Account status refreshed for \($0.email).")
                    } ?? .success(title: "Account Refresh", message: "No signed-in account was found.")
                } catch {
                    return .error(title: "Account Refresh", message: error.localizedDescription)
                }
            }
        )
    }

    #if MAS_BUILD
    private struct LoginRequest: Decodable {
        let action: String
        let enabled: Bool?
        let nonce: String
        let createdAt: Double
    }

    private static var loginRequestsDirectoryURL: URL {
        SharedAppStorage.directoryURL.appendingPathComponent("login-requests", isDirectory: true)
    }

    // The toast reads status from this cache instead of round-tripping on every
    // settings load. The host keeps it fresh: seeded on launch, rewritten after
    // each served request.
    private static var loginStateCacheURL: URL {
        SharedAppStorage.fileURL("login-state.json")
    }

    private func writeLoginStateCache(_ state: LoginItemState) {
        guard let encoded = try? JSONEncoder().encode(state) else { return }
        try? encoded.write(to: AppDelegate.loginStateCacheURL, options: .atomic)
    }

    // Watches the shared login-requests dir (not a single file) because the toast
    // publishes each request via atomic rename, which would invalidate a
    // file-level descriptor. Mirrors SettingsStore.startWatchingSharedDirectory.
    private func startLoginRequestWatcher() {
        let dir = AppDelegate.loginRequestsDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Serve a request that landed before the watcher armed; the directory
        // source only fires on future events.
        serveLoginRequests()
        let descriptor = open(dir.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.serveLoginRequests()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        loginRequestWatcher = source
    }

    // Drains pending login requests by running SMAppService HERE, where
    // Bundle.main is the outer CCTrans.app, then writes the resulting state back
    // for the toast to read. That is the whole point of routing login through the
    // host: registration targets the outer app, not the inner helper.
    private func serveLoginRequests() {
        let dir = AppDelegate.loginRequestsDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let now = Date().timeIntervalSince1970
        // Sweep responses the toast never read (its poll timed out before our
        // write landed). Without this they would accumulate, since the req-* stale
        // guard below never touches resp-* files.
        for url in entries
        where url.lastPathComponent.hasPrefix("resp-") && url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            if now - mtime > 30 {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for url in entries
        where url.lastPathComponent.hasPrefix("req-") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(LoginRequest.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // Mirror the Rust 30s stale guard: a request whose response the toast
            // never read (timeout, crash) must not act on a later, unrelated run.
            if now - request.createdAt > 30 {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let state: LoginItemState
            switch request.action {
            case "set":
                do {
                    state = try LoginItemController.setEnabled(request.enabled ?? false)
                } catch {
                    var failed = LoginItemController.status()
                    failed.message = "Could not update login item: \(error.localizedDescription)"
                    state = failed
                }
            default:
                state = LoginItemController.status()
            }
            let responseURL = dir.appendingPathComponent(
                "resp-\(request.nonce).json",
                isDirectory: false
            )
            if let encoded = try? JSONEncoder().encode(state) {
                try? encoded.write(to: responseURL, options: .atomic)
            }
            // Keep the status cache in lockstep with what we just registered, so
            // the next settings load reflects the toggle without a round-trip.
            writeLoginStateCache(state)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private struct ScreenshotRequest: Decodable {
        let createdAt: Double
    }

    private static var screenshotRequestsDirectoryURL: URL {
        SharedAppStorage.directoryURL.appendingPathComponent("screenshot-requests", isDirectory: true)
    }

    // Mirrors startLoginRequestWatcher: the toast publishes a trigger via atomic
    // rename, so watch the directory (a file-level descriptor would be invalidated).
    private func startScreenshotRequestWatcher() {
        let dir = AppDelegate.screenshotRequestsDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Serve a trigger that landed before the watcher armed.
        serveScreenshotRequests()
        let descriptor = open(dir.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.serveScreenshotRequests()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        screenshotRequestWatcher = source
    }

    // Drains screenshot triggers and runs the capture HERE, where ScreenCaptureKit
    // is attributed to the outer CCTrans.app. translateScreenshot() ignores re-entry
    // while a selection is on screen, so collapsing several triggers into one call
    // is safe.
    private func serveScreenshotRequests() {
        let dir = AppDelegate.screenshotRequestsDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let now = Date().timeIntervalSince1970
        var shouldCapture = false
        for url in entries
        where url.lastPathComponent.hasPrefix("req-") && url.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            // Mirror the Rust 30s stale guard: a trigger left by a crashed/timed-out
            // run must not fire a capture on a later, unrelated launch.
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(ScreenshotRequest.self, from: data),
                  now - request.createdAt <= 30 else {
                continue
            }
            shouldCapture = true
        }
        if shouldCapture {
            translateScreenshot()
        }
    }
    #endif

    private struct PermissionRequest: Decodable {
        let action: String
        let nonce: String
        let createdAt: Double
    }

    private struct PermissionResponse: Encodable {
        let title: String
        let message: String
        let ok: Bool
    }

    private static var permissionRequestsDirectoryURL: URL {
        SharedAppStorage.directoryURL.appendingPathComponent("permission-requests", isDirectory: true)
    }

    // The Tauri permission helper is a nested helper app. Route native TCC
    // requests through this outer host so Screen Recording grants attach to
    // CCTrans.app, the process that actually captures screenshots.
    private func startPermissionRequestWatcher() {
        let dir = AppDelegate.permissionRequestsDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        servePermissionRequests()
        let descriptor = open(dir.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.servePermissionRequests()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        permissionRequestWatcher = source
    }

    private func servePermissionRequests() {
        let dir = AppDelegate.permissionRequestsDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let now = Date().timeIntervalSince1970
        for url in entries
        where url.lastPathComponent.hasPrefix("resp-") && url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            if now - mtime > 30 {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for url in entries
        where url.lastPathComponent.hasPrefix("req-") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(PermissionRequest.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if now - request.createdAt > 30 {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let response = handlePermissionRequest(request)
            let responseURL = dir.appendingPathComponent(
                "resp-\(request.nonce).json",
                isDirectory: false
            )
            if let encoded = try? JSONEncoder().encode(response) {
                try? encoded.write(to: responseURL, options: .atomic)
            }
            writePermissionStatusCache()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func handlePermissionRequest(_ request: PermissionRequest) -> PermissionResponse {
        switch request.action {
        case "show":
            showPermissionHelper()
            return PermissionResponse(
                title: "Permissions",
                message: "Opened the CCTrans permissions window.",
                ok: true
            )
        case "screen":
            let ready = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
            if !ready {
                OnboardingFlowModel.openPrivacySettings("Privacy_ScreenCapture")
            }
            return PermissionResponse(
                title: "Screen Recording",
                message: ready
                    ? "Screen Recording is ready for CCTrans.app."
                    : "macOS did not grant Screen Recording yet. Opened System Settings for the existing grant.",
                ok: ready
            )
        case "input":
            #if MAS_BUILD
            return PermissionResponse(
                title: "Keyboard",
                message: "The App Store build uses pasteboard polling and does not need Input Monitoring.",
                ok: true
            )
            #else
            let ready = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
            return PermissionResponse(
                title: "Keyboard",
                message: ready
                    ? "Keyboard monitoring is ready for CCTrans.app."
                    : "macOS did not grant Input Monitoring yet. Use System Settings if the prompt was already denied.",
                ok: ready
            )
            #endif
        case "accessibility":
            #if MAS_BUILD
            return PermissionResponse(
                title: "Accessibility",
                message: "The App Store build does not request Accessibility.",
                ok: true
            )
            #else
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let ready = AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options)
            return PermissionResponse(
                title: "Accessibility",
                message: ready
                    ? "Accessibility is ready for CCTrans.app."
                    : "macOS did not grant Accessibility yet. Use System Settings if the prompt was already denied.",
                ok: ready
            )
            #endif
        default:
            return PermissionResponse(
                title: "Permission",
                message: "Unknown permission request: \(request.action)",
                ok: false
            )
        }
    }

    private func startUpdaterIfBundled() {
        #if !MAS_BUILD
        // Dev runs execute the bare SwiftPM binary outside an .app bundle, where
        // Sparkle cannot resolve the host bundle and would surface error alerts.
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        #endif
    }

    #if !MAS_BUILD
    @objc private func checkForUpdates() {
        // LSUIElement apps are background apps, so Sparkle's update window can
        // open behind other windows unless the app is activated first.
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(self)
    }
    #endif

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarBadgeImage()
            button.imagePosition = .imageOnly
            button.toolTip = "CCTrans"
            button.setAccessibilityLabel("CCTrans")
        }
        statusItem = item
        rebuildMenu()
    }

    private static func menuBarBadgeImage(highlighted: Bool = false) -> NSImage {
        let size = NSSize(width: 32, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let badgeRect = NSRect(x: 1.5, y: 1.5, width: size.width - 3, height: size.height - 3)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        if highlighted {
            NSColor.controlAccentColor.setFill()
            badgePath.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.labelColor).setStroke()
        badgePath.lineWidth = 1.4
        badgePath.stroke()

        let text = "⌘C" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: highlighted ? NSColor.white : NSColor.labelColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2 + 0.5
            ),
            withAttributes: attributes
        )

        image.isTemplate = !highlighted
        return image
    }

    private func pulseStatusItem() {
        statusPulseTask?.cancel()
        statusItem?.button?.image = Self.menuBarBadgeImage(highlighted: true)
        statusPulseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.statusItem?.button?.image = Self.menuBarBadgeImage()
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "CCTrans")
        appMenu.addItem(menuItem(title: "Quit CCTrans", action: #selector(quit), key: "q", target: self))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem(title: "Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem(title: "Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(menuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private static func imageInfo(for data: Data?) -> String? {
        guard let data,
              let bitmap = NSBitmapImageRep(data: data) else {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px, \(formatter.string(fromByteCount: Int64(data.count)))"
    }

    private static func imageInfo(for data: Data?, diagnostic: String?) -> String? {
        guard let data else {
            if let diagnostic, !diagnostic.isEmpty {
                return "none (\(diagnostic))"
            }
            return nil
        }

        let info = imageInfo(for: data) ?? "attached"
        guard let diagnostic, !diagnostic.isEmpty else {
            return info
        }
        return "\(info), \(diagnostic)"
    }

    #if !MAS_BUILD
    private func startKeyboardMonitor() {
        let onScreenshot: (() -> Void)?
        if didRegisterScreenshotHotKey {
            onScreenshot = nil
        } else {
            onScreenshot = { [weak self] in
                self?.translateScreenshot()
            }
        }

        keyboardMonitor = KeyboardMonitor(
            onCopyPress: { [weak self] in
                self?.pulseStatusItem()
            },
            onDoubleCopy: { [weak self] in
                self?.triggerClipboardTranslation()
            },
            onScreenshot: onScreenshot
        )
        keyboardMonitor?.start()
    }
    #endif

    private func startScreenshotHotKey() {
        screenshotHotKey = ScreenshotHotKey { [weak self] in
            self?.translateScreenshot()
        }
        let status = screenshotHotKey?.start() ?? OSStatus(-1)
        didRegisterScreenshotHotKey = status == noErr
        if status != noErr {
            print("Could not register Shift+Cmd+2. Carbon status: \(status)")
        }
    }

    private func createKeepAliveWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces]
        // The Apple Translation host must live in an ordered-front window for
        // SwiftUI to run its .translationTask; the keep-alive window is the
        // app's only permanent window, so it doubles as that host.
        window.contentView = AppleTranslationHost.shared.makeHostingView()
        // LSUIElement apps with only transient toast windows can be auto-terminated after the toast closes.
        window.orderFront(nil)
        keepAliveWindow = window
    }

    private func startPasteboardMonitor() {
        pasteboardMonitor = PasteboardMonitor { [weak self] in
            self?.triggerClipboardTranslation()
        }
        pasteboardMonitor?.start()
    }

    private func triggerClipboardTranslation() {
        let now = Date()
        if let previous = lastClipboardTriggerAt,
           now.timeIntervalSince(previous) < 0.6 {
            return
        }

        lastClipboardTriggerAt = now
        translateClipboard()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(disabledTitle("CCTrans"))
        if let installLocationTitle = AppInstallLocationNotice.menuTitle(forBundleURL: Bundle.main.bundleURL) {
            menu.addItem(disabledTitle(installLocationTitle))
        }
        menu.addItem(NSMenuItem.separator())

        menu.addItem(submenuItem(title: "Translation Model", submenu: translationModelMenu()))

        let sourceLanguageMenu = NSMenu()
        for language in TranslationLanguage.sourceLanguageNames {
            sourceLanguageMenu.addItem(checkableItem(
                title: language,
                checked: settingsStore.settings.sourceLanguage == language,
                action: #selector(setSourceLanguage(_:)),
                representedObject: language
            ))
        }
        menu.addItem(submenuItem(title: "Source Language", submenu: sourceLanguageMenu))

        let languageMenu = NSMenu()
        for language in TranslationLanguage.targetLanguageNames {
            languageMenu.addItem(checkableItem(
                title: language,
                checked: settingsStore.settings.targetLanguage == language,
                action: #selector(setTargetLanguage(_:)),
                representedObject: language
            ))
        }
        menu.addItem(submenuItem(title: "Target Language", submenu: languageMenu))

        let positionMenu = NSMenu()
        for position in ToastPosition.allCases {
            positionMenu.addItem(checkableItem(
                title: position.title,
                checked: settingsStore.settings.toastPosition == position,
                action: #selector(setToastPosition(_:)),
                representedObject: position.rawValue
            ))
        }
        menu.addItem(submenuItem(title: "Toast Position", submenu: positionMenu))

        menu.addItem(NSMenuItem.separator())
        // Cmd+, is the platform-standard settings shortcut; surfacing it in the menu
        // also teaches the binding even though status menus only fire it while open.
        menu.addItem(actionItem(title: "Getting Started...", action: #selector(showOnboardingWindow)))
        menu.addItem(menuItem(title: "Settings...", action: #selector(showSettingsWindow), key: ",", target: self))
        menu.addItem(actionItem(title: "Permissions...", action: #selector(showPermissionHelper)))
        #if !MAS_BUILD
        if updaterController != nil {
            menu.addItem(actionItem(title: "Check for Updates...", action: #selector(checkForUpdates)))
        }
        #endif
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem(title: "Quit", action: #selector(quit)))

        statusItem?.menu = menu
    }

    private func translateClipboard() {
        // Clipboard updates usually land just after the key event, so a short delay avoids reading stale text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else {
                return
            }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            performTextTranslation(text, sourceTitle: "Clipboard")
        }
    }

    private func translateScreenshot() {
        guard !isScreenshotSelectionActive else {
            return
        }

        currentTextTranslationTask?.cancel()
        currentScreenshotTranslationTask?.cancel()
        isScreenshotSelectionActive = true
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            let data: Data
            do {
                data = try await ScreenshotCapture.captureSelectedRegionPNG()
                isScreenshotSelectionActive = false
            } catch is CancellationError {
                isScreenshotSelectionActive = false
                return
            } catch ScreenshotCaptureError.selectionCancelled {
                isScreenshotSelectionActive = false
                return
            } catch ScreenshotCaptureError.selectionInProgress {
                isScreenshotSelectionActive = false
                return
            } catch {
                isScreenshotSelectionActive = false
                guard !Task.isCancelled else {
                    return
                }
                show(error: error, title: "Screenshot", inputText: "[selected screenshot]")
                return
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                let imageInfo = Self.imageInfo(for: data)
                showTranslationLoading(originalText: "[selected screenshot]", sourceTitle: "Screenshot")
                let requestSeq = translationRequestSequence
                onboardingController?.flowModel?.noteTranslationStarted(
                    requestID: requestSeq,
                    isEligible: false
                )
                let result = try await translationService.translateImage(
                    pngData: data,
                    settings: settingsStore.settings,
                    credentials: credentialsProvider.credentials()
                )
                guard !Task.isCancelled else {
                    return
                }
                show(
                    result: result,
                    title: "Screenshot",
                    inputText: "[selected screenshot]",
                    imageInfo: imageInfo,
                    requestSeq: requestSeq
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                show(error: error, title: "Screenshot", inputText: "[selected screenshot]")
            }
        }
        currentScreenshotTranslationTask = task
    }

    private func performTextTranslation(
        _ text: String,
        sourceTitle: String,
        settings overrideSettings: TranslatorSettings? = nil
    ) {
        let settings = overrideSettings ?? settingsStore.settings
        let previousTask = currentTextTranslationTask
        let previousUsesLocalBackend = currentTextTranslationUsesLocalBackend
        let usesLocalBackend = settings.provider == .localHyMT2
        let warmupModel = localWarmupModel(settings: settings)
        let shouldAnnounceWarmup = warmupModel.map { $0.id != lastReadyLocalModelID } ?? false

        previousTask?.cancel()
        currentScreenshotTranslationTask?.cancel()
        currentTextTranslationUsesLocalBackend = usesLocalBackend
        if shouldAnnounceWarmup, let warmupModel {
            localModelWarmupNotifier.warmingUp(modelTitle: warmupModel.title)
        }
        showTranslationLoading(originalText: text, sourceTitle: sourceTitle, settings: settings)
        lastPartialTranslatedLength = 0
        let requestSeq = translationRequestSequence
        onboardingController?.flowModel?.noteTranslationStarted(
            requestID: requestSeq,
            isEligible: true
        )
        let task = Task { [weak self] in
            if usesLocalBackend && previousUsesLocalBackend {
                await previousTask?.value
            }
            guard let self else {
                return
            }
            guard !Task.isCancelled else {
                return
            }

            do {
                let screenContext = await contextImagePNGDataIfNeeded(settings: settings)
                guard !Task.isCancelled else {
                    return
                }
                let imageInfo = Self.imageInfo(for: screenContext.pngData, diagnostic: screenContext.diagnostic)
                let result = try await translationService.translateText(
                    text,
                    settings: settings,
                    credentials: credentialsProvider.credentials(),
                    contextImagePNGData: screenContext.pngData,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            self?.showTranslationPartial(
                                partial,
                                originalText: text,
                                sourceTitle: sourceTitle,
                                requestSeq: requestSeq,
                                settings: settings
                            )
                        }
                    }
                )
                guard !Task.isCancelled else {
                    return
                }
                if shouldAnnounceWarmup, let warmupModel {
                    lastReadyLocalModelID = warmupModel.id
                    localModelWarmupNotifier.completed(modelTitle: warmupModel.title)
                }
                show(
                    result: result,
                    title: sourceTitle,
                    inputText: text,
                    imageInfo: imageInfo,
                    requestSeq: requestSeq,
                    settings: settings
                )
            } catch is CancellationError {
                return
            } catch {
                if shouldAnnounceWarmup, let warmupModel {
                    localModelWarmupNotifier.failed(modelTitle: warmupModel.title, error: error)
                }
                show(error: error, title: sourceTitle, inputText: text, settings: settings)
            }
        }
        currentTextTranslationTask = task
    }

    private func contextImagePNGDataIfNeeded(settings: TranslatorSettings) async -> ScreenContextCaptureResult {
        // Off by default: attach a full-screen context screenshot only when the user opts in
        // (includeScreenContextForLLM) AND the selected OpenRouter text model accepts images.
        // Text-only models would otherwise force a silent switch to a vision model and fail.
        // Caret-localized cropping was removed (App Review 2.4.5), so this sends the whole display.
        guard settings.includeScreenContextForLLM,
              settings.provider == .openRouter,
              OpenRouterModelCatalog.model(id: settings.openRouterTextModel)?.supportsVision == true else {
            return ScreenContextCaptureResult(pngData: nil, diagnostic: nil)
        }

        return await ScreenshotCapture.captureMainDisplayContextPNGIfAvailable()
    }

    @MainActor
    private func show(
        result: TranslationResult,
        title: String,
        inputText: String,
        imageInfo: String?,
        requestSeq: Int,
        settings: TranslatorSettings? = nil
    ) {
        requestLogStore.add(source: title, input: inputText, result: result, imageInfo: imageInfo)
        showTranslationResult(
            result,
            inputText: inputText,
            requestSeq: requestSeq,
            settings: settings ?? settingsStore.settings
        )
    }

    @MainActor
    private func show(
        error: Error,
        title: String,
        inputText: String? = nil,
        settings: TranslatorSettings? = nil
    ) {
        showTranslationError(
            error,
            sourceTitle: title,
            originalText: inputText ?? title,
            settings: settings ?? settingsStore.settings
        )
        // A missing on-device pack can't be downloaded from the invisible
        // translation host, so surface the visible onboarding window where the
        // system download sheet can actually present.
        if let translationError = error as? TranslationError,
           case .appleLanguagePackMissing = translationError {
            showOnboardingWindow()
        }
    }

    private func translationModelMenu() -> NSMenu {
        let menu = NSMenu()
        let openRouterMenu = NSMenu()
        let settings = settingsStore.settings
        let defaults = TranslatorSettings()

        #if !MAS_BUILD
        let localMenu = NSMenu()
        localMenu.addItem(checkableItem(
            title: "Default (\(LocalModelRegistry.defaultModel().title))",
            checked: settings.provider == .localHyMT2 && settings.localModelID == defaults.localModelID,
            action: #selector(setTranslationModel(_:)),
            representedObject: "localHyMT2:\(defaults.localModelID)"
        ))
        localMenu.addItem(NSMenuItem.separator())
        for model in prioritizedLocalModels(settings: settings) {
            localMenu.addItem(checkableItem(
                title: model.title,
                checked: settings.provider == .localHyMT2 && settings.localModelID == model.id,
                action: #selector(setTranslationModel(_:)),
                representedObject: "localHyMT2:\(model.id)"
            ))
        }
        menu.addItem(submenuItem(title: "Local Model", submenu: localMenu))
        #endif

        openRouterMenu.addItem(checkableItem(
            title: "Default (\(OpenRouterModelCatalog.title(for: defaults.openRouterTextModel)))",
            checked: settings.provider == .openRouter && settings.openRouterTextModel == defaults.openRouterTextModel,
            action: #selector(setTranslationModel(_:)),
            representedObject: "openRouter:\(defaults.openRouterTextModel)"
        ))
        openRouterMenu.addItem(NSMenuItem.separator())
        for model in prioritizedOpenRouterModels(settings: settings) {
            openRouterMenu.addItem(checkableItem(
                title: "\(model.title) · \(model.pricingTitle) · \(model.modalityTitle)",
                checked: settings.provider == .openRouter && settings.openRouterTextModel == model.id,
                action: #selector(setTranslationModel(_:)),
                representedObject: "openRouter:\(model.id)"
            ))
        }

        menu.addItem(checkableItem(
            title: "Apple Translation · On-device",
            checked: settings.provider == .appleTranslation,
            action: #selector(setTranslationModel(_:)),
            representedObject: "appleTranslation:"
        ))
        // CCTrans Cloud (kargn.as managed): translate with no OpenRouter key. Model-less,
        // so a flat item like Apple Translation. Keep it available in the Mac App
        // Store build; signed macOS builds authenticate with StoreKit AppTransaction
        // or the local App Store receipt fallback.
        menu.addItem(checkableItem(
            title: "CCTrans Cloud · No API key",
            checked: settings.provider == .kargnasManaged,
            action: #selector(setTranslationModel(_:)),
            representedObject: "kargnasManaged:"
        ))
        menu.addItem(submenuItem(title: "OpenRouter LLM", submenu: openRouterMenu))
        return menu
    }

    private func prioritizedLocalModels(settings: TranslatorSettings) -> [LocalModelSpec] {
        let models = LocalModelRegistry.models(customModelsPath: settings.customLocalModelsPath)
        return prioritize(models, favorites: settings.favoriteLocalModelIDs, id: \.id)
    }

    private func prioritizedOpenRouterModels(settings: TranslatorSettings) -> [OpenRouterModelSpec] {
        prioritize(OpenRouterModelCatalog.models, favorites: settings.favoriteOpenRouterModels, id: \.id)
    }

    private func prioritize<T>(_ values: [T], favorites: [String], id: KeyPath<T, String>) -> [T] {
        values.sorted { left, right in
            let leftID = left[keyPath: id]
            let rightID = right[keyPath: id]
            let leftFavorite = favorites.firstIndex(of: leftID)
            let rightFavorite = favorites.firstIndex(of: rightID)
            switch (leftFavorite, rightFavorite) {
            case let (left?, right?):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return leftID < rightID
            }
        }
    }

    @objc private func setTranslationModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else {
            return
        }
        // omittingEmptySubsequences keeps the trailing empty model id of
        // model-less providers ("appleTranslation:") so the count guard holds.
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let provider = TranslationProvider(rawValue: parts[0]) else {
            return
        }

        var settings = settingsStore.settings
        settings.provider = provider
        switch provider {
        case .localHyMT2:
            settings.localModelID = parts[1]
        case .openRouter:
            settings.openRouterTextModel = parts[1]
        case .appleTranslation, .kargnasManaged:
            // Model-less providers: the engine is fixed (Apple) or server-chosen
            // (CCTrans Cloud), so there is no per-model id to apply from the menu.
            break
        }
        settingsStore.settings = settings
        rebuildMenu()
    }

    @objc private func setSourceLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else {
            return
        }
        settingsStore.settings.sourceLanguage = language
        rebuildMenu()
    }

    @objc private func setTargetLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else {
            return
        }
        settingsStore.settings.targetLanguage = language
        rebuildMenu()
    }

    @objc private func setToastPosition(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let position = ToastPosition(rawValue: rawValue) else {
            return
        }
        var settings = settingsStore.settings
        settings.toastPosition = position
        if position != .custom {
            settings.toastCustomPosition = nil
        }
        settingsStore.settings = settings
        rebuildMenu()
    }

    @objc private func showSettingsWindow() {
        _ = openTauriSurface("settings")
    }

    private func openTauriSurface(_ surface: String) -> Bool {
        launchTauriHelper(
            arguments: ["--surface", surface],
            activate: true,
            replaceExistingMatching: "--surface \(surface)"
        )
    }

    private func showTranslationLoading(
        originalText: String,
        sourceTitle: String,
        settings: TranslatorSettings? = nil
    ) {
        let settings = settings ?? settingsStore.settings
        let languages = resolvedLanguages(for: originalText, settings: settings)
        showTranslationPopover(TranslationPreviewPayload(
            mode: "loading",
            sourceLanguage: languages.sourceLanguage,
            targetLanguage: languages.targetLanguage,
            didReverseBecauseLanguagesMatched: languages.didReverseBecauseLanguagesMatched,
            originalText: originalText,
            translatedText: "",
            errorText: nil,
            providerTitle: settings.provider.title,
            model: activeModelTitle(settings: settings),
            costCredits: nil
        ), sourceTitle: sourceTitle, settings: settings)
    }

    private func showTranslationResult(
        _ result: TranslationResult,
        inputText: String,
        requestSeq: Int,
        settings: TranslatorSettings? = nil
    ) {
        onboardingController?.flowModel?.noteTranslationSucceeded(requestID: requestSeq)
        let settings = settings ?? settingsStore.settings
        let languages = resolvedLanguages(for: inputText, settings: settings)
        showTranslationPopover(TranslationPreviewPayload(
            mode: "translated",
            sourceLanguage: result.sourceLanguage ?? result.detectedSourceLanguage ?? languages.sourceLanguage,
            targetLanguage: result.targetLanguage ?? languages.targetLanguage,
            didReverseBecauseLanguagesMatched: languages.didReverseBecauseLanguagesMatched,
            originalText: inputText,
            translatedText: result.text,
            translatedImageURL: result.imageURL,
            errorText: nil,
            providerTitle: result.providerTitle,
            model: TranslationPreviewMetadata.modelTitle(for: result, settings: settings),
            modelWarning: TranslationPreviewMetadata.modelWarning(for: result, inputText: inputText, settings: settings),
            costCredits: result.usage?.costCredits
        ), sourceTitle: result.providerTitle, settings: settings)
    }

    private func showTranslationPartial(
        _ partial: String,
        originalText: String,
        sourceTitle: String,
        requestSeq: Int,
        settings: TranslatorSettings
    ) {
        // Drop deltas from a superseded request: a newer Cmd+C already bumped the sequence and owns
        // the toast, so writing this stale partial would overwrite the new translation in place.
        guard requestSeq == translationRequestSequence else { return }
        // MainActor Task hops are not ordered, so ignore any delta that does not extend what we last
        // showed; this keeps the streamed text monotonic instead of flickering backward.
        let length = partial.count
        guard length > lastPartialTranslatedLength else { return }
        lastPartialTranslatedLength = length

        let languages = resolvedLanguages(for: originalText, settings: settings)
        showTranslationPopover(TranslationPreviewPayload(
            mode: "translated",
            sourceLanguage: languages.sourceLanguage,
            targetLanguage: languages.targetLanguage,
            didReverseBecauseLanguagesMatched: languages.didReverseBecauseLanguagesMatched,
            originalText: originalText,
            translatedText: partial,
            errorText: nil,
            providerTitle: settings.provider.title,
            model: activeModelTitle(settings: settings),
            costCredits: nil
        ), sourceTitle: sourceTitle, settings: settings)
    }

    private func showTranslationError(
        _ error: Error,
        sourceTitle: String,
        originalText: String,
        settings: TranslatorSettings? = nil
    ) {
        let settings = settings ?? settingsStore.settings
        let languages = resolvedLanguages(for: originalText, settings: settings)
        showTranslationPopover(TranslationPreviewPayload(
            mode: "error",
            sourceLanguage: languages.sourceLanguage,
            targetLanguage: languages.targetLanguage,
            didReverseBecauseLanguagesMatched: languages.didReverseBecauseLanguagesMatched,
            originalText: originalText,
            translatedText: "",
            errorText: error.localizedDescription,
            providerTitle: settings.provider.title,
            model: activeModelTitle(settings: settings),
            costCredits: nil,
            permissionAction: permissionAction(for: error)
        ), sourceTitle: sourceTitle, settings: settings)
    }

    private func showTranslationPopoverSmoke() {
        showTranslationPopover(
            TranslationPreviewPayload(
                mode: "loading",
                sourceLanguage: "English",
                targetLanguage: "Korean",
                originalText: "Hover smoke text",
                translatedText: "",
                providerTitle: "Smoke",
                model: "Smoke"
            ),
            sourceTitle: "Smoke"
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            showTranslationPopover(
                TranslationPreviewPayload(
                    mode: "translated",
                    sourceLanguage: "English",
                    targetLanguage: "Korean",
                    originalText: "Hover smoke text",
                    translatedText: "마우스 오버 테스트가 제자리에서 갱신되었습니다.",
                    providerTitle: "Smoke",
                    model: "Smoke"
                ),
                sourceTitle: "Smoke"
            )
        }
    }

    private func showTranslationPopover(
        _ payload: TranslationPreviewPayload,
        sourceTitle: String,
        settings displaySettings: TranslatorSettings? = nil
    ) {
        // The toast always positions itself from the user's toastPosition setting; caret-anchored
        // placement was removed (App Review 2.4.5 — it needed the AXUIElement caret API).
        if payload.mode == "loading" {
            // A new loading frame is a new user request; bumping the sequence tells the persistent
            // toast window to reposition and show, instead of only updating its text in place.
            translationRequestSequence += 1
        }

        var payload = payload
        payload.requestSequence = translationRequestSequence
        writeTranslationPreviewState(payload)
    }

    private func writeTranslationPreviewState(_ payload: TranslationPreviewPayload) {
        do {
            try SharedAppStorage.ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: SharedAppStorage.fileURL("translation-preview.json"), options: .atomic)
        } catch {
            print("Could not write translation preview state: \(error.localizedDescription)")
        }
    }

    // The persisted preview survives restarts, but the in-memory sequence restarts at 0. A stale
    // nonzero sequence would either show last session's translation on launch or collide with this
    // session's fresh numbers and suppress a real one. Reset it to 0 to match the in-memory baseline.
    private func resetPersistedToastSequence() {
        let url = SharedAppStorage.fileURL("translation-preview.json")
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        object["requestSequence"] = 0
        // Also drop last session's result so a relaunched (or orphaned) toast
        // can't render a stale "translation"; zeroing the sequence alone is not
        // enough because the persisted content survives restarts.
        for key in ["translatedText", "errorText", "originalText", "translatedImageURL"] where object[key] != nil {
            object[key] = ""
        }
        guard let updated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        try? updated.write(to: url, options: .atomic)
    }

    private func startPersistentToastProcess() {
        // One hidden Tauri process is launched up front and reused for every translation, so the
        // WebView (and its CJK font cache) stays warm instead of cold-starting on each Cmd+C.
        _ = launchTauriHelper(
            arguments: ["--translation-preview"],
            activate: false,
            replaceExistingMatching: "--translation-preview"
        )
    }

    private func resolvedLanguages(
        for text: String,
        settings: TranslatorSettings
    ) -> ResolvedTranslationLanguages {
        TranslationLanguageResolver.resolve(
            text: text,
            sourceLanguage: settings.sourceLanguage,
            targetLanguage: settings.targetLanguage
        )
    }

    private func activeModelTitle(settings: TranslatorSettings) -> String {
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
        case .kargnasManaged:
            // Server picks the model; the client never knows which (§4). Show the brand.
            TranslationProvider.kargnasManaged.title
        }
    }

    private func permissionAction(for error: Error) -> String? {
        guard let screenshotError = error as? ScreenshotCaptureError,
              case .permissionDenied = screenshotError else {
            return nil
        }
        return "screenRecording"
    }

    private func localWarmupModel(settings: TranslatorSettings) -> LocalModelSpec? {
        guard settings.provider == .localHyMT2 else {
            return nil
        }
        return LocalModelRegistry.model(
            id: settings.localModelID,
            customModelsPath: settings.customLocalModelsPath
        ) ?? LocalModelRegistry.defaultModel(customModelsPath: settings.customLocalModelsPath)
    }

    private func launchTauriHelper(
        arguments: [String],
        activate: Bool,
        replaceExistingMatching match: String
    ) -> Bool {
        guard let appURL = resolveTauriHelperAppURL() else {
            return false
        }

        terminateTauriHelper(matching: match)

        var launchArguments = arguments
        if let workspaceRootURL = resolveWorkspaceRootURL() {
            launchArguments.append(contentsOf: ["--workspace-root", workspaceRootURL.path])
        }
        // The helper is a nested app with its own bundle id, but settings,
        // permissions, and toast state belong to the outer host app.
        launchArguments.append(contentsOf: ["--host-app-id", SharedAppStorage.appIdentifier])
        #if MAS_BUILD
        // The Svelte settings/permission surfaces hide sandbox-incompatible
        // options (Python local models, Accessibility) based on this flag.
        launchArguments.append(contentsOf: ["--app-variant", "mas"])
        if isRunningInAppSandbox {
            // Sandboxed callers cannot pass argv through NSWorkspace (macOS
            // documents OpenConfiguration.arguments as ignored), so the helper
            // claims a one-shot launch file from the App Group directory instead.
            guard writeHelperLaunchFile(arguments: launchArguments) else {
                print("Could not write helper launch file; not launching the Tauri helper.")
                return false
            }
        }
        #endif

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.createsNewApplicationInstance = true
        configuration.arguments = launchArguments
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                print("Could not open Tauri helper app: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func terminateTauriHelper(matching match: String) {
        #if MAS_BUILD
        guard isRunningInAppSandbox else {
            terminateTauriHelperWithPkill(matching: match)
            return
        }
        // The sandbox forbids signaling other processes (pkill is a no-op)
        // and helper argv is empty anyway, so match against the claimed
        // launch files instead. Deleting the file doubles as the shutdown
        // signal: the persistent toast watcher exits when its lease vanishes,
        // and terminate() politely closes window surfaces.
        let launchesDir = SharedAppStorage.directoryURL
            .appendingPathComponent("helper-launches", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: launchesDir, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix("claimed-") {
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let arguments = object["arguments"] as? [String],
                  arguments.joined(separator: " ").contains(match) else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
            if let pid = object["pid"] as? Int32,
               let running = NSRunningApplication(processIdentifier: pid),
               running.bundleIdentifier == "\(SharedAppStorage.appIdentifier).helper"
                || running.bundleIdentifier == SharedAppStorage.appIdentifier {
                running.terminate()
            }
        }
        #else
        terminateTauriHelperWithPkill(matching: match)
        #endif
    }

    private func terminateTauriHelperWithPkill(matching match: String) {
        // Match the helper binary name, not this bundle's absolute path: a helper left over
        // from another checkout or an old install path (e.g. the pre-rebrand transtoast
        // workspace) watches the same shared state file, so a path-scoped pkill would let it
        // survive and render a second toast window for every translation.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "cctrans-tauri.*\(match)"]
        try? process.run()
    }

    private var isRunningInAppSandbox: Bool {
        SharedAppStorage.isAppSandboxed
    }

    #if MAS_BUILD
    // One file per launch under <shared>/helper-launches; the helper claims it
    // by an atomic rename, so concurrent launches (persistent toast + a
    // settings window) cannot adopt each other's arguments. File names embed
    // epoch milliseconds so the helper claims the oldest request first.
    private func writeHelperLaunchFile(arguments: [String]) -> Bool {
        let launchesDir = SharedAppStorage.directoryURL
            .appendingPathComponent("helper-launches", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: launchesDir, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(launchesDir.path): \(error.localizedDescription)")
            return false
        }

        // Purge stale pending requests (launches that never booted) so a
        // macOS window-restore ghost cannot adopt one much later.
        let now = Date().timeIntervalSince1970
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: launchesDir, includingPropertiesForKeys: nil
        )) ?? []
        for file in existing where file.lastPathComponent.hasPrefix("pending-") {
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let createdAt = object["createdAt"] as? Double else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if now - createdAt > 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let payload: [String: Any] = [
            "arguments": arguments,
            "createdAt": now,
        ]
        let fileURL = launchesDir.appendingPathComponent(
            "pending-\(Int(now * 1000))-\(UUID().uuidString).json", isDirectory: false
        )
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("Could not write \(fileURL.path): \(error.localizedDescription)")
            return false
        }
    }
    #endif

    private func resolveTauriHelperAppURL() -> URL? {
        let explicitAppPath = argumentValue(after: "--tauri-helper-app")
        var candidates: [URL] = []
        if let explicitAppPath, !explicitAppPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitAppPath))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("CCTransTauri.app", isDirectory: true))
            candidates.append(resourceURL.appendingPathComponent("CCTrans.app", isDirectory: true))
        }
        if let workspaceRootURL = resolveWorkspaceRootURL() {
            candidates.append(workspaceRootURL.appendingPathComponent("src-tauri/target/debug/bundle/macos/CCTrans.app", isDirectory: true))
            candidates.append(workspaceRootURL.appendingPathComponent("src-tauri/target/release/bundle/macos/CCTrans.app", isDirectory: true))
        }

        return candidates.first { candidate in
            FileManager.default.isExecutableFile(
                atPath: candidate.appendingPathComponent("Contents/MacOS/cctrans-tauri").path
            )
        }
    }

    private func resolveWorkspaceRootURL() -> URL? {
        var candidates: [URL] = []
        if let workspaceRootPath = argumentValue(after: "--workspace-root"),
           !workspaceRootPath.isEmpty {
            candidates.append(URL(fileURLWithPath: workspaceRootPath))
        }
        if let workspaceRootPath = ProcessInfo.processInfo.environment["CCTRANS_WORKSPACE_ROOT"],
           !workspaceRootPath.isEmpty {
            candidates.append(URL(fileURLWithPath: workspaceRootPath))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        candidates.append(Bundle.main.bundleURL)
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }

        for candidate in candidates {
            if let rootURL = firstAncestorWithPackageManifest(from: candidate) {
                return rootURL
            }
        }
        return nil
    }

    private func firstAncestorWithPackageManifest(from url: URL) -> URL? {
        WorkspaceRootResolver.firstAncestorWithPackageManifest(from: url)
    }

    @objc private func showLocalModelSetup() {
        _ = openTauriSurface("local-model-setup")
    }

    @objc private func showRequestLogs() {
        _ = openTauriSurface("request-logs")
    }

    @objc private func requestKeyboardPermission() {
        reportKeyboardPermissionStatus(requestIfMissing: true)
    }

    @objc private func showPermissionHelper() {
        // Both variants use the native permissions window. The old Tauri
        // permission-helper surface ran in the helper process, whose TCC
        // identity is not the one that taps the keyboard or captures the
        // screen — its pills and requests applied to the wrong app.
        // An unfinished session resumes its durable checkpoint. After onboarding
        // is complete this entry point remains a focused permissions-only window.
        let hasCompletedOnboarding = settingsStore.settings.hasCompletedOnboarding
        presentOnboarding(
            mode: hasCompletedOnboarding ? .permissionsOnly : .fullFlow,
            resumeProgress: !hasCompletedOnboarding
        )
    }

    @objc private func showOnboardingWindow() {
        // Explicit Getting Started is a durable restart, not only a one-window
        // override. If the user closes and relaunches, model remains the checkpoint.
        var progressError: String?
        do {
            try onboardingProgressStore.save(.model)
        } catch {
            progressError = "Couldn’t restart onboarding progress. \(error.localizedDescription)"
        }
        presentOnboarding(
            mode: .fullFlow,
            resumeProgress: false,
            initialProgressError: progressError
        )
    }

    private func presentOnboarding(
        mode: OnboardingFlowModel.Mode,
        resumeProgress: Bool,
        initialProgressError: String? = nil
    ) {
        // A fresh flow model each time so it reflects the current provider/target
        // language. The Apple language-pack download model is now built at
        // provider-selection time inside the flow model, not here.
        let flowModel = OnboardingFlowModel(
            mode: mode,
            settingsStore: settingsStore,
            progressStore: onboardingProgressStore,
            resumeProgress: resumeProgress,
            accountClient: accountClient,
            appleSignIn: appleSignIn,
            existingAccount: loadExistingAccountSummary(),
            onPermissionStatusChanged: { [weak self] in self?.writePermissionStatusCache() }
        )
        flowModel.progressError = initialProgressError
        let controller = onboardingController ?? OnboardingWindowController()
        onboardingController = controller
        controller.show(flowModel: flowModel)
    }

    private func loadExistingAccountSummary() -> CctransAccountSummary? {
        guard (try? CctransAccountStorage.sessionCoordinator.loadToken()) != nil else {
            return nil
        }
        return try? CctransAccountStorage.summaryStore.load()
    }

    private func showOnboardingOnLaunchIfNeeded() {
        // A quiet menu-bar-only start applies only once onboarding is finished AND
        // permissions are granted: an unfinished wizard or a missing grant means the
        // app cannot work yet, so the window still shows (which also keeps a reviewer's
        // fresh-install first launch visible for App Review Guideline 2.1 — a fresh
        // install has neither the completion flag nor a Screen Recording grant).
        if settingsStore.settings.startMenuBarOnly,
           settingsStore.settings.hasCompletedOnboarding,
           onboardingProgressStore.loadStoredCheckpoint() == nil,
           !requiredPermissionsMissing() {
            return
        }
        surfaceLaunchWindow()
    }

    private func recoverCompletedOnboardingIfNeeded() {
        guard onboardingProgressStore.load() == .completed else { return }
        if !settingsStore.settings.hasCompletedOnboarding {
            var settings = settingsStore.settings
            settings.hasCompletedOnboarding = true
            settingsStore.settings = settings
        }
        let sharedSettingsWriteSucceeded = settingsStore.persistCurrentSettings()
        if OnboardingCompletionMarkerPolicy.shouldClearMarker(
            hasCompletedOnboarding: settingsStore.settings.hasCompletedOnboarding,
            sharedSettingsWriteSucceeded: sharedSettingsWriteSucceeded
        ) {
            try? onboardingProgressStore.clear()
        }
    }

    // Show whichever window is useful right now, shared by launch and Dock/Finder
    // reopen so both stay consistent: unfinished onboarding resumes its durable
    // model/permissions/try-it checkpoint, completed onboarding shows only a
    // missing permissions surface, and Settings opens once nothing remains.
    private func surfaceLaunchWindow() {
        if let checkpoint = onboardingProgressStore.loadStoredCheckpoint(),
           checkpoint != .completed {
            presentOnboarding(mode: .fullFlow, resumeProgress: true)
        } else if !settingsStore.settings.hasCompletedOnboarding {
            presentOnboarding(mode: .fullFlow, resumeProgress: true)
        } else if requiredPermissionsMissing() {
            presentOnboarding(mode: .permissionsOnly, resumeProgress: false)
        } else {
            showSettingsWindow()
        }
    }

    private func requiredPermissionsMissing() -> Bool {
        #if MAS_BUILD
        // Input Monitoring is no longer requested on MAS (App Review 2.4.5): double-⌘C
        // runs through pasteboard polling with no permission. Only Screen Recording (for
        // screenshot translation) remains a grantable permission worth surfacing.
        return !OnboardingPermissionReadiness.isReady(
            screenRecording: CGPreflightScreenCaptureAccess(),
            inputMonitoring: false,
            accessibility: false,
            requiresKeyboardPermission: false
        )
        #else
        return !OnboardingPermissionReadiness.isReady(
            screenRecording: CGPreflightScreenCaptureAccess(),
            inputMonitoring: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted(),
            requiresKeyboardPermission: true
        )
        #endif
    }

    private func reportKeyboardPermissionStatus(requestIfMissing: Bool) {
        #if MAS_BUILD
        // The MAS build needs no keyboard permission: double-⌘C is detected through
        // PasteboardMonitor (clipboard polling) and Shift+Cmd+2 through the Carbon
        // ScreenshotHotKey. Requesting Input Monitoring here would violate App Review 2.4.5.
        _ = requestIfMissing
        print("MAS build: copy detection uses pasteboard polling — no keyboard permission required.")
        #else
        let canListenToEvents = CGPreflightListenEventAccess()
        let isAccessibilityTrusted = AXIsProcessTrusted()

        if canListenToEvents || isAccessibilityTrusted {
            print("Global keyboard monitoring is available.")
            return
        }

        if requestIfMissing {
            _ = CGRequestListenEventAccess()
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        print("Keyboard permission needed. Enable Input Monitoring or Accessibility for CCTrans, then relaunch the app.")
        #endif
    }

    // The settings/permission UI lives in the Tauri helper, a different TCC subject
    // than this outer CCTrans.app that actually holds the grants (it owns the
    // CGEventTap and ScreenCaptureKit). The helper cannot preflight our permissions,
    // so publish them to the shared dir for it to read back.
    private func writePermissionStatusCache() {
        #if MAS_BUILD
        // MAS strips Accessibility entirely (App Review 2.4.5): the caret-anchor feature was
        // removed and Cmd+C runs through pasteboard polling, so the binary must NOT call
        // AXIsProcessTrusted at all — a query-only call on a 2s timer still links the
        // Accessibility framework into the store binary and re-surfaces the rejection.
        // Keyboard is always satisfied via pasteboard polling; accessibility is N/A.
        let accessibility = false
        let keyboardReady = true
        #else
        let accessibility = AXIsProcessTrusted()
        let keyboardReady = CGPreflightListenEventAccess() || accessibility
        #endif
        let status: [String: Bool] = [
            "keyboard": keyboardReady,
            "accessibility": accessibility,
            "screen": CGPreflightScreenCaptureAccess(),
        ]
        guard status != lastWrittenPermissionStatus else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else {
            return
        }
        try? SharedAppStorage.ensureDirectoryExists()
        try? data.write(to: SharedAppStorage.fileURL("permission-status.json"), options: .atomic)
        lastWrittenPermissionStatus = status
    }

    // macOS posts no notification when the user toggles a grant in System Settings,
    // and this accessory app never gains focus to observe the return, so a short
    // poll is the only way the helper's "Refresh" reflects a just-granted permission.
    // The write is change-gated, so a steady state costs three preflight syscalls per
    // tick and no disk/watcher activity.
    private func startPermissionStatusTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.writePermissionStatusCache()
            }
        }
        timer.tolerance = 0.5
        permissionStatusTimer = timer
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func disabledTitle(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func menuItem(title: String, action: Selector, key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }

    private func checkableItem(
        title: String,
        checked: Bool,
        action: Selector,
        representedObject: Any
    ) -> NSMenuItem {
        let item = actionItem(title: title, action: action)
        item.state = checked ? .on : .off
        item.representedObject = representedObject
        return item
    }

    private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

#if !MAS_BUILD
extension AppDelegate: SPUUpdaterDelegate {}
#endif
