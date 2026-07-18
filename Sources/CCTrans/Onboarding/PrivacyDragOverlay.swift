import AppKit
import SwiftUI

// Floating "drag me into the list" chip pinned next to the System Settings
// window. Shown when CCTrans sends the user to a Privacy pane: macOS often does
// NOT auto-add the app to that pane's list, and the wizard window is usually
// buried behind System Settings at that moment — so the drag source must float
// above Settings, positioned against it.
//
// Window tracking uses CGWindowListCopyWindowInfo bounds + owner PID (public
// API; needs no permission — only window *titles* are gated behind Screen
// Recording). Settings is matched by PID, not owner name, so localized names
// ("시스템 설정") don't break it.
@MainActor
final class PrivacyDragOverlayController {
    static let shared = PrivacyDragOverlayController()

    private var panel: NSPanel?
    private var timer: Timer?
    private var isSatisfied: () -> Bool = { false }
    // The Settings window can take a moment to appear after the open-URL call
    // (and vanishes briefly during Space transitions); don't close until it has
    // been missing past this deadline.
    private var missingDeadline = Date.distantPast
    // Re-anchor only when the Settings window actually moved; snapping every
    // tick would fight the user after they drag the chip aside manually.
    private var lastSettingsFrame: NSRect?

    // Height covers chip + the bouncing up-arrow strip above it.
    private let panelSize = NSSize(width: 340, height: 112)

    func show(appBundleURL: URL, isSatisfied: @escaping () -> Bool) {
        self.isSatisfied = isSatisfied
        missingDeadline = Date().addingTimeInterval(4)

        let hosting = NSHostingController(rootView: PrivacyDragOverlayView(
            appBundleURL: appBundleURL,
            onClose: { [weak self] in self?.close() }
        ))

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.contentViewController = hosting
        } else {
            panel = NSPanel(contentViewController: hosting)
            // Non-activating: dragging from the chip must not steal focus from
            // System Settings, or the Privacy list would lose its scroll/selection.
            panel.styleMask = [.borderless, .nonactivatingPanel]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            // NSPanel hides on app deactivate by default — fatal here, since the
            // user is by definition IN System Settings while this chip matters.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        panel.setContentSize(panelSize)
        reposition()
        panel.orderFrontRegardless()
        startTracking()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func startTracking() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if isSatisfied() {
            close()
            return
        }
        if let frame = Self.settingsWindowFrame() {
            missingDeadline = Date().addingTimeInterval(2)
            if frame != lastSettingsFrame {
                lastSettingsFrame = frame
                position(nextTo: frame)
            }
        } else if Date() > missingDeadline {
            // User closed System Settings; the chip has nothing to point at.
            close()
        }
    }

    private func reposition() {
        if let frame = Self.settingsWindowFrame() {
            position(nextTo: frame)
        } else if let screen = NSScreen.main {
            // Settings not up yet: park top-right of the current screen; the
            // tracking timer snaps to the window once it appears.
            let visible = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(
                x: visible.maxX - panelSize.width - 24,
                y: visible.maxY - panelSize.height - 24
            ))
        }
    }

    private func position(nextTo settingsFrame: NSRect) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(settingsFrame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        // Overlay INSIDE the Settings window, right under the Privacy app list.
        // Offsets measured from the real pane (AX probe): sidebar is 215pt wide,
        // the app list starts ~105pt from the window top and a typical list
        // (~6 rows × 47pt) ends near 385pt. AX can't be used live here — during
        // onboarding this app has no AX grant yet (and the MAS build must not
        // link AX at all) — so a fixed drop zone at 400pt sits just below
        // typical lists; longer lists slide under it, and the chip stays
        // movable (isMovableByWindowBackground) for that case.
        let sidebarWidth: CGFloat = 215
        let listBottomOffset: CGFloat = 400
        let paneLeft = settingsFrame.minX + sidebarWidth
        let paneWidth = settingsFrame.width - sidebarWidth
        var x = paneLeft + (paneWidth - panelSize.width) / 2
        var y = settingsFrame.maxY - listBottomOffset - panelSize.height
        x = max(visible.minX + 8, min(x, visible.maxX - panelSize.width - 8))
        y = max(visible.minY + 8, min(y, visible.maxY - panelSize.height - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Frontmost normal-layer window of the System Settings process, in Cocoa
    // (bottom-left origin) coordinates.
    private static func settingsWindowFrame() -> NSRect? {
        guard let settings = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return nil }

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == settings.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            // CGWindow bounds are top-left-origin global coords; flip against the
            // primary screen (screens[0], whose Cocoa origin is 0,0).
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(
                x: rect.origin.x,
                y: primaryHeight - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )
        }
        return nil
    }
}

private struct PrivacyDragOverlayView: View {
    let appBundleURL: URL
    let onClose: () -> Void
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 6) {
            // The chip sits BELOW the Privacy app list, so the affordance arrow
            // bounces upward, pointing at the drop target.
            Image(systemName: "arrow.up")
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .offset(y: bounce ? -4 : 2)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bounce)

            HStack(spacing: 10) {
                DraggableAppIcon(appBundleURL: appBundleURL)
                    .frame(width: 44, height: 44)
                    // Grab-hand badge on the icon itself: marks the icon (not the
                    // whole chip) as the thing to pick up. Hover shows the real
                    // open-hand cursor too (AppIconDragView.resetCursorRects).
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 5, y: 5)
                            .allowsHitTesting(false)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("← Drag this icon into the list above")
                        .font(.callout).bold()
                    Text("Drop it into the app list, then turn the switch on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .frame(width: 340)
        .onAppear { bounce = true }
    }
}
