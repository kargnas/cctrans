import AppKit
import CCTransCore

/// One-time "star the repo" ask for standalone installs (brew cask / GitHub DMG
/// / install-app.zsh copies). Channel rules live in GitHubStarPromptPolicy;
/// this type gathers platform facts, drives the user's `gh` CLI, and shows the
/// alert. Everything is best-effort: a missing or broken `gh` must never
/// surface an error to the user.
@MainActor
final class GitHubStarPrompter {
    nonisolated static let repo = "kargnas/cctrans"
    // scripts/install-app.zsh writes this same key via `defaults write` after
    // its own terminal prompt, so clone users are never asked twice.
    nonisolated static let handledDefaultsKey = "githubStarPromptHandled"

    private let defaults: UserDefaults = .standard

    enum GHStarState {
        case ghUnavailable
        case notAuthenticated
        case alreadyStarred
        case notStarred
    }

    func scheduleIfEligible(hasWorkspaceRoot: Bool, hasCompletedInitialSetup: Bool) {
        let channel = GitHubStarPromptPolicy.channel(
            bundlePathHasAppSuffix: Bundle.main.bundlePath.hasSuffix(".app"),
            hasMacAppStoreReceipt: Self.hasMacAppStoreReceipt(),
            isAppSandboxed: Self.isAppSandboxed(),
            hasWorkspaceRoot: hasWorkspaceRoot
        )
        guard GitHubStarPromptPolicy.shouldPrompt(
            channel: channel,
            alreadyHandled: defaults.bool(forKey: Self.handledDefaultsKey),
            hasCompletedInitialSetup: hasCompletedInitialSetup
        ) else {
            return
        }

        Task { [weak self] in
            // Let the menu bar, monitors, and any update check settle first; the
            // ask is the least important thing happening at launch.
            try? await Task.sleep(for: .seconds(5))
            let state = await Task.detached(priority: .utility) {
                GitHubStarPrompter.checkStarState()
            }.value
            self?.handle(state: state)
        }
    }

    private func handle(state: GHStarState) {
        switch state {
        case .ghUnavailable, .notAuthenticated:
            // Leave the key unset: if the user installs or logs into gh later,
            // a future launch can still ask once.
            return
        case .alreadyStarred:
            // Remember so future launches skip the gh round-trip entirely.
            defaults.set(true, forKey: Self.handledDefaultsKey)
        case .notStarred:
            promptToStar()
        }
    }

    private func promptToStar() {
        // LSUIElement apps are background apps; without activation the alert
        // would open behind other windows (same reason checkForUpdates does it).
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enjoying CCTrans?"
        alert.informativeText = """
        Star \(Self.repo) on GitHub to support development. \
        This uses your local GitHub CLI (gh) login and only asks once.
        """
        alert.addButton(withTitle: "Star on GitHub")
        alert.addButton(withTitle: "No Thanks")
        let response = alert.runModal()

        // Either answer counts as handled: the deal is "asks once", so a failed
        // PUT below is logged but does not re-arm the prompt.
        defaults.set(true, forKey: Self.handledDefaultsKey)

        guard response == .alertFirstButtonReturn else {
            return
        }
        Task.detached(priority: .utility) {
            if !GitHubStarPrompter.starRepo() {
                NSLog("CCTrans: gh api PUT user/starred/\(GitHubStarPrompter.repo) failed; check `gh auth status` and token scopes.")
            }
        }
    }

    // MARK: - Platform facts

    private nonisolated static func hasMacAppStoreReceipt() -> Bool {
        // Checked via the fixed bundle path instead of the deprecated
        // Bundle.appStoreReceiptURL; every MAS install carries this receipt.
        let receipt = Bundle.main.bundleURL
            .appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path)
    }

    private nonisolated static func isAppSandboxed() -> Bool {
        SharedAppStorage.isAppSandboxed
    }

    // MARK: - gh plumbing (blocking; call off the main actor)

    nonisolated static func checkStarState() -> GHStarState {
        guard let gh = locateGH() else {
            return .ghUnavailable
        }
        guard runGH(gh, ["auth", "status"]) else {
            return .notAuthenticated
        }
        // GET user/starred/<repo> answers 204 (exit 0) only when already
        // starred; 404 (non-zero) means not starred yet.
        return runGH(gh, ["api", "user/starred/\(repo)"]) ? .alreadyStarred : .notStarred
    }

    nonisolated static func starRepo() -> Bool {
        guard let gh = locateGH() else {
            return false
        }
        return runGH(gh, ["api", "-X", "PUT", "user/starred/\(repo)"])
    }

    private nonisolated static func locateGH() -> String? {
        // GUI apps do not inherit the shell PATH, so probe the usual installs
        // (Apple Silicon brew, Intel brew/manual, system) directly.
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func runGH(_ ghPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = arguments
        // Discard output; an unread pipe could fill and stall gh.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Smoke support

    /// Headless report for the `--github-star-smoke` one-shot CLI path: prints
    /// the channel decision and the gh pipeline result without showing UI.
    nonisolated static func smokeReport(hasWorkspaceRoot: Bool) -> String {
        let channel = GitHubStarPromptPolicy.channel(
            bundlePathHasAppSuffix: Bundle.main.bundlePath.hasSuffix(".app"),
            hasMacAppStoreReceipt: hasMacAppStoreReceipt(),
            isAppSandboxed: isAppSandboxed(),
            hasWorkspaceRoot: hasWorkspaceRoot
        )
        let handled = UserDefaults.standard.bool(forKey: handledDefaultsKey)
        return """
        channel: \(channel)
        alreadyHandled: \(handled)
        ghStarState: \(checkStarState())
        """
    }
}
