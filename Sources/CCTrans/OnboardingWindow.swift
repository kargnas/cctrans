import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// A native, main-process onboarding/status window.
//
// Why this exists: CCTrans is a menu-bar accessory app, so before this it had no
// real window at all — App Review (Guideline 2.1) repeatedly reported "does not
// launch a main window for review / unable to verify functionality." The only
// prior window surfaces were Tauri helper (CCTransTauri) windows running in a
// SEPARATE process, which also made the helper — not CCTrans — own any visible
// permission UI. Hosting this window in the MAIN app process fixes both:
//   1. App Review sees a window owned by CCTrans itself.
//   2. Input Monitoring / Screen Recording preflight + request run in the SAME
//      process that actually taps the keyboard, so the status shown and the
//      grant requested apply to the right TCC identity (the helper's did not).
@MainActor
final class OnboardingModel: ObservableObject {
    struct Permission: Identifiable {
        let id: String
        let title: String
        let detail: String
        var granted: Bool
        let request: () -> Void
        let fallback: (() -> Void)?
    }

    @Published var permissions: [Permission] = []
    @Published private var attemptedRequests: Set<String> = []
    // Non-nil only when Apple Translation is the active provider; lets onboarding
    // offer a language-pack download from this visible window (the invisible
    // keep-alive host cannot present Apple's download sheet).
    let translationDownload: TranslationDownloadModel?
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onPermissionStatusChanged: () -> Void
    let appBundleURL = Bundle.main.bundleURL
    // Set by the window controller so the SwiftUI "Done" button can close the window.
    var onDismiss: () -> Void = {}

    init(
        translationDownload: TranslationDownloadModel?,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onPermissionStatusChanged: @escaping () -> Void
    ) {
        self.translationDownload = translationDownload
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onPermissionStatusChanged = onPermissionStatusChanged
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
        // Input Monitoring is requested ONLY on direct-distribution builds. App Review
        // Guideline 2.4.5 forbids requesting it to drive a hotkey, so the MAS build omits
        // this card and detects the double ⌘C through PasteboardMonitor (clipboard-
        // changeCount polling), which needs no permission at all.
        rows.append(Permission(
            id: "input",
            title: "Input Monitoring",
            detail: "Detects the double ⌘C that triggers a translation.",
            granted: CGPreflightListenEventAccess(),
            request: {
                _ = CGRequestListenEventAccess()
                Self.openPrivacySettings("Privacy_ListenEvent")
            },
            fallback: { Self.openPrivacySettings("Privacy_ListenEvent") }
        ))
        #endif
        rows.append(Permission(
            id: "screen",
            title: "Screen Recording",
            detail: attemptedRequests.contains("screen")
                ? "If no macOS prompt appeared, enable CCTrans in Screen Recording settings."
                : "Captures the selected region for screenshot translation.",
            granted: CGPreflightScreenCaptureAccess(),
            request: { [weak self] in self?.requestScreenRecordingAccess() },
            fallback: { Self.openPrivacySettings("Privacy_ScreenCapture") }
        ))
        #if !MAS_BUILD
        // Accessibility is requested ONLY on direct-distribution builds. The MAS build reads
        // the selection through the sandbox and the caret-anchor feature was removed, so it must
        // not reference the Accessibility API at all (App Review 2.4.5). Compile-gated (not the
        // old runtime `if !isMAS`) so the AX symbols never link into the store binary.
        rows.append(Permission(
            id: "ax",
            title: "Accessibility",
            detail: "Lets CCTrans read the current text selection.",
            granted: AXIsProcessTrusted(),
            request: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            fallback: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        ))
        #endif
        permissions = rows
        onPermissionStatusChanged()
    }

    func didAttempt(_ permission: Permission) -> Bool {
        attemptedRequests.contains(permission.id)
    }

    func revealAppBundle() {
        NSWorkspace.shared.activateFileViewerSelecting([appBundleURL])
    }

    private func requestScreenRecordingAccess() {
        attemptedRequests.insert("screen")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
        if !CGPreflightScreenCaptureAccess() {
            Self.openPrivacySettings("Privacy_ScreenCapture")
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.refresh()
        }
    }

    private static func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CCTrans").font(.title2).bold()
                    Text("Translate selected text instantly.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("How to use") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Select any text", systemImage: "1.circle.fill")
                    Label("Press ⌘C twice quickly", systemImage: "2.circle.fill")
                    Label("A translation popover appears", systemImage: "3.circle.fill")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Permissions") {
                VStack(spacing: 10) {
                    ForEach(model.permissions) { permission in
                        PermissionRowView(
                            permission: permission,
                            didAttempt: model.didAttempt(permission)
                        )
                    }
                    if model.allGranted {
                        Text("All set — CCTrans is ready.")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }

            if !model.allGranted {
                AppBundleDragCard(
                    appBundleURL: model.appBundleURL,
                    onReveal: model.revealAppBundle
                )
            }

            if let translationDownload = model.translationDownload {
                TranslationDownloadSection(model: translationDownload)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Settings…") { model.onOpenSettings() }
                Button("Quit CCTrans") { model.onQuit() }
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Done") { model.onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // Taller when the translation row is present so nothing clips.
        .frame(width: 500, height: model.translationDownload == nil ? 620 : 700)
    }
}

private struct AppBundleDragCard: View {
    let appBundleURL: URL
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DraggableAppIcon(appBundleURL: appBundleURL)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(appBundleURL.lastPathComponent).bold()
                Text("Drag the app icon into the open Privacy list if macOS does not add it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appBundleURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Reveal") { onReveal() }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

private struct DraggableAppIcon: NSViewRepresentable {
    let appBundleURL: URL

    func makeNSView(context: Context) -> AppIconDragView {
        AppIconDragView(appBundleURL: appBundleURL)
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {
        nsView.appBundleURL = appBundleURL
    }
}

private final class AppIconDragView: NSImageView, NSDraggingSource {
    var appBundleURL: URL {
        didSet {
            image = NSWorkspace.shared.icon(forFile: appBundleURL.path)
        }
    }

    init(appBundleURL: URL) {
        self.appBundleURL = appBundleURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appBundleURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        isEditable = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(appBundleURL.absoluteString, forType: .fileURL)
        item.setPropertyList([appBundleURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}

private struct PermissionRowView: View {
    let permission: OnboardingModel.Permission
    let didAttempt: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(permission.granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).bold()
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !permission.granted {
                VStack(alignment: .trailing, spacing: 6) {
                    // App Review 5.1.1(iv): the priming button shown before the OS Screen
                    // Recording prompt must not say "Grant"/"Allow"; Apple asks for neutral
                    // wording like "Continue"/"Next".
                    Button("Continue") { permission.request() }
                    if didAttempt, let fallback = permission.fallback {
                        Button("Open Settings") { fallback() }
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model: OnboardingModel

    init(model: OnboardingModel) {
        self.model = model
        model.onDismiss = { [weak self] in self?.window?.close() }
    }

    func show() {
        model.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to CCTrans"
            window.styleMask = [.titled, .closable, .miniaturizable]
            // Reused across reopens, so it must survive being closed.
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // An LSUIElement/accessory app has no Dock icon; without an explicit
        // activate the window can open behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
