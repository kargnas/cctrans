import CCTransCore
import Foundation

/// Persists the OpenRouter API key entered during onboarding to the same
/// credential file the Rust translation engine reads back.
///
/// This is a byte-for-byte mirror of `write_env_key` / `credential_env_path` in
/// `src-tauri/src/lib.rs`. Both processes touch the same file, so the line format
/// (`KEY=value`, comments preserved, unrelated keys preserved, single trailing
/// newline) must match exactly — otherwise one side clobbers the other's edits.
enum OpenRouterKeyStore {
    static let keyName = "OPENROUTER_API_KEY"

    enum KeyStoreError: LocalizedError {
        case homeNotSet
        case invalidValue
        var errorDescription: String? {
            switch self {
            case .homeNotSet: "Could not locate your home directory."
            case .invalidValue: "The API key must be a single line."
            }
        }
    }

    // Same resolution as credential_env_path(): the sandboxed MAS build stores
    // credentials in the shared app-group dir because the helper runs in a
    // separate container and cannot see plain Application Support; direct builds
    // use ~/.config/cctrans/.env.
    static func credentialFileURL() throws -> URL {
        #if MAS_BUILD
        return SharedAppStorage.fileURL("credentials.env")
        #else
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw KeyStoreError.homeNotSet
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config/cctrans/.env", isDirectory: false)
        #endif
    }

    /// Writes (or, with a nil value, removes) the key. Replaces an existing
    /// `OPENROUTER_API_KEY=` line in place and leaves every other line untouched.
    static func write(_ value: String?) throws {
        if let value, !OnboardingCredentialValue.isSafe(value) {
            throw KeyStoreError.invalidValue
        }
        let url = try credentialFileURL()

        var lines: [String] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            // Keep internal blank lines but drop the single trailing empty a final
            // newline produces, matching Rust's str::lines() so a rewrite doesn't
            // accumulate blank lines.
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
        }

        var replaced = false
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let matchesKey = !trimmed.hasPrefix("#") && {
                guard let equals = trimmed.firstIndex(of: "=") else { return false }
                return trimmed[..<equals].trimmingCharacters(in: .whitespaces) == keyName
            }()
            if !matchesKey {
                result.append(line)
                continue
            }
            if let value {
                result.append("\(keyName)=\(value)")
                replaced = true
            } else {
                replaced = true
            }
        }
        if let value, !replaced {
            result.append("\(keyName)=\(value)")
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Trailing newline only when there is content, matching Rust's format!("{}\n", …).
        let data = result.isEmpty ? "" : result.joined(separator: "\n") + "\n"
        try data.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
