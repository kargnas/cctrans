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
            save()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(TranslatorSettings.self, from: data) {
            settings = Self.normalize(decoded)
        } else if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(TranslatorSettings.self, from: data) {
            settings = Self.normalize(decoded)
            save()
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

    private func save() {
        let settingsToSave = Self.normalize(settings)
        guard settingsToSave != Self.codeDefaults else {
            defaults.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: settingsURL)
            return
        }

        guard let data = try? JSONEncoder().encode(settingsToSave) else {
            return
        }
        do {
            try SharedAppStorage.ensureDirectoryExists()
            try data.write(to: settingsURL, options: .atomic)
            defaults.removeObject(forKey: key)
        } catch {
            defaults.set(data, forKey: key)
        }
    }
}
