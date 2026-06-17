import CCTransCore
import Foundation
import Testing

@Test func findsNearestPackageManifestAncestor() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cctrans-workspace-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("Sources/CCTrans", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Package.swift"))
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(WorkspaceRootResolver.firstAncestorWithPackageManifest(from: nested) == root.standardizedFileURL)
}

@Test func stopsAtFilesystemRootWhenManifestIsMissing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cctrans-installed-app-\(UUID().uuidString)", isDirectory: true)
    let appContents = root.appendingPathComponent("CCTrans.app/Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: appContents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(WorkspaceRootResolver.firstAncestorWithPackageManifest(from: appContents) == nil)
}
