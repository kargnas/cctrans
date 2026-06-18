import Foundation

public enum AppInstallLocationNotice {
    public static func menuTitle(forBundleURL bundleURL: URL) -> String? {
        let path = bundleURL.standardizedFileURL.path
        guard !isInApplicationsDirectory(path: path) else {
            return nil
        }
        return "Running from: \(path)"
    }

    private static func isInApplicationsDirectory(path: String) -> Bool {
        path == "/Applications" || path.hasPrefix("/Applications/")
    }
}
