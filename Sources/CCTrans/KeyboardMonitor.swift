import AppKit
import CCTransCore

// Global ⌘C / double-⌘C detection via a listen-only CGEventTap (rides Input Monitoring)
// with an NSEvent-monitor (Accessibility) fallback. NOT compiled into the Mac App Store
// build: App Review Guideline 2.4.5 forbids requesting Input Monitoring to drive a hotkey,
// and a sandboxed global NSEvent monitor needs Accessibility, which is equally off-limits.
// The MAS build detects the double ⌘C through PasteboardMonitor (clipboard-changeCount
// polling) and registers Shift+Cmd+2 through the permission-free Carbon ScreenshotHotKey,
// so KeyboardMonitor has no role there.
#if !MAS_BUILD
@MainActor
final class KeyboardMonitor {
    private struct KeySnapshot: Sendable {
        let keyCode: UInt16
        let modifierFlags: UInt
        let timestamp: TimeInterval
        let isRepeat: Bool

        init(event: NSEvent) {
            keyCode = event.keyCode
            modifierFlags = event.modifierFlags.rawValue
            timestamp = event.timestamp
            isRepeat = event.isARepeat
        }
    }

    private let onCopyPress: () -> Void
    private let onDoubleCopy: () -> Void
    private let onScreenshot: (() -> Void)?
    private var detector = DoublePressDetector()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    init(
        onCopyPress: @escaping () -> Void,
        onDoubleCopy: @escaping () -> Void,
        onScreenshot: (() -> Void)?
    ) {
        self.onCopyPress = onCopyPress
        self.onDoubleCopy = onDoubleCopy
        self.onScreenshot = onScreenshot
    }

    func start() {
        guard eventTap == nil, globalMonitor == nil, localMonitor == nil else {
            return
        }

        // Prefer a listen-only CGEventTap: it rides the Input Monitoring
        // privilege, which (per Apple DTS) keeps working under App Sandbox /
        // Mac App Store, unlike the NSEvent global monitor that needs
        // Accessibility. Only attempt it when the privilege is already granted,
        // so tap creation cannot fail into a half-started state.
        if CGPreflightListenEventAccess(), startEventTap() {
            return
        }

        #if !MAS_BUILD
        // Direct-distribution fallback: users who granted Accessibility but not
        // Input Monitoring keep the historical NSEvent-monitor behavior.
        startNSEventMonitors()
        #else
        // Sandboxed build without Input Monitoring: PasteboardMonitor still
        // detects the same text being copied twice, so the feature degrades
        // instead of dying. The permission helper points users at the setting.
        print("Input Monitoring not granted; falling back to pasteboard-based copy detection.")
        #endif
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        eventTap = nil
        eventTapRunLoopSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        detector.reset()
    }

    // MARK: - CGEventTap path

    private func startEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap source is scheduled on the main run loop, so the callback
            // always arrives on the main thread.
            MainActor.assumeIsolated {
                monitor.handleTapEvent(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Could not create the keyboard event tap despite Input Monitoring being granted.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapRunLoopSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        // The system silently disables taps that stall (or on user-input
        // protection); re-enable instead of losing the shortcut until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
            return
        }
        // A session tap sees our own keystrokes too. The old NSEvent split
        // (global monitor = other apps, local monitor = us) never triggered
        // copy translation from inside CCTrans, so keep that behavior by
        // checking who is frontmost.
        let selfIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        handle(KeySnapshot(event: nsEvent), monitorsCopyShortcut: !selfIsFrontmost)
    }

    // MARK: - NSEvent fallback path (direct distribution only)

    private func startNSEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let snapshot = KeySnapshot(event: event)
            Task { @MainActor [weak self] in
                self?.handle(snapshot)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(KeySnapshot(event: event), monitorsCopyShortcut: false)
            return event
        }
    }

    // MARK: - Shared shortcut handling

    private func handle(_ event: KeySnapshot) {
        handle(event, monitorsCopyShortcut: true)
    }

    private func handle(_ event: KeySnapshot, monitorsCopyShortcut: Bool) {
        guard !event.isRepeat else {
            return
        }

        let flags = NSEvent.ModifierFlags(rawValue: event.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
        let commandOnly = flags.contains(.command)
            && !flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)

        if commandOnly, event.keyCode == 8 {
            onCopyPress()
            if monitorsCopyShortcut, detector.registerPress(at: event.timestamp) {
                onDoubleCopy()
            }
            return
        }

        let screenshotShortcut = flags.contains(.command)
            && flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)

        if screenshotShortcut, event.keyCode == 19 {
            onScreenshot?()
        }
    }
}
#endif
