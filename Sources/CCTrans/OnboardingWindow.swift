import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

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
    }

    @Published var permissions: [Permission] = []
    let isMAS: Bool
    // Non-nil only when Apple Translation is the active provider; lets onboarding
    // offer a language-pack download from this visible window (the invisible
    // keep-alive host cannot present Apple's download sheet).
    let translationDownload: TranslationDownloadModel?
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    // Set by the window controller so the SwiftUI "Done" button can close the window.
    var onDismiss: () -> Void = {}

    init(
        isMAS: Bool,
        translationDownload: TranslationDownloadModel?,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.isMAS = isMAS
        self.translationDownload = translationDownload
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        refresh()
    }

    var allGranted: Bool { permissions.allSatisfy { $0.granted } }

    // Re-read the live TCC state. Input Monitoring's preflight result is cached per
    // process, so a grant only flips to true after macOS auto-relaunches the app
    // (which it does on an Input Monitoring grant); Refresh covers Screen Recording
    // and the post-relaunch read.
    func refresh() {
        var rows: [Permission] = [
            Permission(
                id: "input",
                title: "Input Monitoring",
                detail: "Detects the double ⌘C that triggers a translation.",
                granted: CGPreflightListenEventAccess(),
                request: {
                    _ = CGRequestListenEventAccess()
                    Self.openPrivacySettings("Privacy_ListenEvent")
                }
            ),
            Permission(
                id: "screen",
                title: "Screen Recording",
                detail: "Captures the selected region for screenshot translation.",
                granted: CGPreflightScreenCaptureAccess(),
                request: {
                    _ = CGRequestScreenCaptureAccess()
                    Self.openPrivacySettings("Privacy_ScreenCapture")
                }
            ),
        ]
        // The MAS build routes selection capture through Input Monitoring + the
        // sandbox, so it never asks for Accessibility; only the Developer ID build
        // reads the selection via the Accessibility API.
        if !isMAS {
            rows.append(Permission(
                id: "ax",
                title: "Accessibility",
                detail: "Lets CCTrans read the current text selection.",
                granted: AXIsProcessTrusted(),
                request: {
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
            ))
        }
        permissions = rows
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
                        PermissionRowView(permission: permission)
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
        .frame(width: 460, height: model.translationDownload == nil ? 540 : 620)
    }
}

private struct PermissionRowView: View {
    let permission: OnboardingModel.Permission

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
                Button("Grant") { permission.request() }
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
