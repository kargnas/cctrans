import Darwin
import Foundation

package struct CctransAccountFileLock: Sendable {
    package let fileURL: URL

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    package func withExclusiveLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = Darwin.open(
            fileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixError()
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw posixError()
            }
        }

        do {
            let value = try operation()
            guard flock(descriptor, LOCK_UN) == 0 else {
                throw posixError()
            }
            return value
        } catch {
            _ = flock(descriptor, LOCK_UN)
            throw error
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
