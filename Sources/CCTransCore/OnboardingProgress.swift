import Foundation

public enum OnboardingCheckpoint: String, Codable, CaseIterable, Sendable {
    case model
    case permissions
    case tryIt
    case completed

    public var next: OnboardingCheckpoint? {
        switch self {
        case .model:
            .permissions
        case .permissions:
            .tryIt
        case .tryIt:
            .completed
        case .completed:
            nil
        }
    }
}

public struct OnboardingProgressStore: Sendable {
    private struct Payload: Codable {
        let version: Int
        let checkpoint: OnboardingCheckpoint
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> OnboardingCheckpoint {
        loadStoredCheckpoint() ?? .model
    }

    public func loadStoredCheckpoint() -> OnboardingCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else {
            return nil
        }
        return payload.checkpoint
    }

    public func save(_ checkpoint: OnboardingCheckpoint) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            Payload(version: 1, checkpoint: checkpoint)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
