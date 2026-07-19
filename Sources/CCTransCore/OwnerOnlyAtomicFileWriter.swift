import Darwin
import Foundation

public enum OwnerOnlyAtomicFileWriter {
    public static func write(_ data: Data, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporaryFile = false

        try synchronizeDirectory(directoryURL)
    }

    public static func removeIfExists(at fileURL: URL) throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == NSFileNoSuchFileError else {
                throw error
            }
            return
        }

        try synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ directoryURL: URL) throws {
        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
