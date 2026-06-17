import Foundation

public enum WorkspaceRootResolver {
    public static func firstAncestorWithPackageManifest(from url: URL) -> URL? {
        firstAncestor(containing: "Package.swift", from: url)
    }

    public static func firstAncestor(containing fileName: String, from url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }

        var visited = Set<String>()
        while !candidate.path.isEmpty, visited.insert(candidate.path).inserted {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(fileName).path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
        return nil
    }
}
