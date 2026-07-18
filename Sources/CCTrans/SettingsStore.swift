import CCTransCore
import Foundation

final class SettingsStore {
    private let key = "as.kargn.cctrans.settings"
    private let defaults: UserDefaults
    private let settingsURL = SharedAppStorage.fileURL("settings-overrides.json")
    private var directoryWatcher: DispatchSourceFileSystemObject?
    // Suppresses the save() side effect while applying an external file change, so
    // reloading a toast-written override never echoes the same value back to disk.
    private var isApplyingExternalChange = false
    private var isNormalizingSettings = false
    private(set) var hadExistingAppStateAtLaunch: Bool
    private(set) var lastSharedSaveSucceeded = true

    // Invoked on the main queue after an external settings-file change is applied,
    // so the menu-bar app can rebuild its menu to match the shared override file.
    var onExternalChange: (() -> Void)?

    private static var buildVariant: SettingsBuildVariant {
        #if MAS_BUILD
        .macAppStore
        #else
        .direct
        #endif
    }

    private static var codeDefaults: TranslatorSettings {
        TranslatorSettings.defaults(for: buildVariant)
    }

    private static func normalize(_ settings: TranslatorSettings) -> TranslatorSettings {
        settings.normalized(for: buildVariant)
    }

    var settings: TranslatorSettings {
        didSet {
            guard !isApplyingExternalChange else { return }
            if !isNormalizingSettings {
                let normalized = Self.normalize(settings)
                if normalized != settings {
                    isNormalizingSettings = true
                    settings = normalized
                    isNormalizingSettings = false
                    return
                }
            }
            lastSharedSaveSucceeded = save()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Override files intentionally disappear at code defaults, so directory
        // existence is the durable migration signal for default-only upgrades.
        let appDataDirectoryExisted = FileManager.default.fileExists(
            atPath: SharedAppStorage.directoryURL.path
        )
        let sharedData = try? Data(contentsOf: settingsURL)
        let legacyData = defaults.data(forKey: key)
        hadExistingAppStateAtLaunch = appDataDirectoryExisted || sharedData != nil || legacyData != nil

        if let data = sharedData,
           let decoded = try? JSONDecoder().decode(TranslatorSettings.self, from: data) {
            settings = Self.normalize(decoded)
        } else if let data = legacyData,
           let decoded = try? JSONDecoder().decode(TranslatorSettings.self, from: data) {
            settings = Self.normalize(decoded)
            lastSharedSaveSucceeded = save()
        } else {
            settings = Self.codeDefaults
        }
        startWatchingSharedDirectory()
    }

    deinit {
        directoryWatcher?.cancel()
    }

    // Reloads settings from the shared override file. The Tauri toast writes the
    // global target language here, so the menu-bar app must adopt that change
    // instead of holding a stale in-memory copy (a second, diverging source).
    func reloadFromDisk() {
        let loaded: TranslatorSettings
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(TranslatorSettings.self, from: data) {
            loaded = Self.normalize(decoded)
        } else {
            loaded = Self.codeDefaults
        }
        guard loaded != settings else { return }
        isApplyingExternalChange = true
        settings = loaded
        isApplyingExternalChange = false
        onExternalChange?()
    }

    // Watches the shared app-data directory rather than the file itself, because
    // atomic writes replace the file via rename and would invalidate a file-level
    // descriptor after the first event.
    private func startWatchingSharedDirectory() {
        try? SharedAppStorage.ensureDirectoryExists()
        let descriptor = open(SharedAppStorage.directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reloadFromDisk()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directoryWatcher = source
    }

    @discardableResult
    func persistCurrentSettings() -> Bool {
        lastSharedSaveSucceeded = save()
        return lastSharedSaveSucceeded
    }

    private func save() -> Bool {
        let settingsToSave = Self.normalize(settings)
        guard settingsToSave != Self.codeDefaults else {
            defaults.removeObject(forKey: key)
            do {
                if FileManager.default.fileExists(atPath: settingsURL.path) {
                    try FileManager.default.removeItem(at: settingsURL)
                }
                return true
            } catch {
                return false
            }
        }

        guard let data = try? JSONEncoder().encode(settingsToSave) else {
            return false
        }
        do {
            try SharedAppStorage.ensureDirectoryExists()
            try data.write(to: settingsURL, options: .atomic)
            defaults.removeObject(forKey: key)
            return true
        } catch {
            defaults.set(data, forKey: key)
            return false
        }
    }
}
