import Foundation

enum SharedAppStorage {
    static let productAppIdentifier = "as.kargn.cctrans"
    static var appIdentifier: String {
        Bundle.main.bundleIdentifier ?? productAppIdentifier
    }

    // True when this process runs inside an App Sandbox container. Behavior
    // gates on the actual sandbox rather than the MAS_BUILD compile flag, so
    // MAS-compiled dev binaries launched bare keep direct-style behavior.
    static var isAppSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    #if MAS_BUILD
    // Under App Sandbox the menu-bar app and the NSWorkspace-launched Tauri
    // helper live in different containers (different bundle ids), so plain
    // Application Support is not shared between them. The team-id-prefixed
    // App Group is the one location both may read and write; on macOS such
    // groups need no portal registration or provisioning-profile entry.
    static let appGroupIdentifier = "6YQH3QFFK8.as.kargn.cctrans"
    #endif

    static var directoryURL: URL {
        #if MAS_BUILD
        if isProductionSandboxedMAS,
           let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            // Mirrors shared_data_dir() in src-tauri/src/lib.rs — both sides
            // must resolve byte-identical paths or toast state stops flowing.
            return groupURL
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(appIdentifier, isDirectory: true)
        }
        // Loud fallback: without the group container the helper cannot see
        // any of this state and toasts/settings silently stop working.
        print("App Group container \(appGroupIdentifier) unavailable; falling back to sandbox-local storage.")
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appIdentifier, isDirectory: true)
    }

    static func fileURL(_ name: String) -> URL {
        directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    #if MAS_BUILD
    private static var isProductionSandboxedMAS: Bool {
        appIdentifier == productAppIdentifier && isAppSandboxed
    }
    #endif
}
