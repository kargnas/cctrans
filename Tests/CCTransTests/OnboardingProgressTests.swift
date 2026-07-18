import CCTransCore
import Foundation
import Testing

@Suite
struct OnboardingProgressTests {
    @Test
    func missingFileStartsAtModel() throws {
        let fixture = try makeFixture()

        #expect(fixture.store.load() == .model)
    }

    @Test
    func everyCheckpointRoundTrips() throws {
        let fixture = try makeFixture()

        for checkpoint in OnboardingCheckpoint.allCases {
            try fixture.store.save(checkpoint)
            #expect(fixture.store.load() == checkpoint)
        }
    }

    @Test
    func corruptPayloadFallsBackToModel() throws {
        let fixture = try makeFixture()
        try Data(#"{"version":1,"checkpoint":"unknown"}"#.utf8)
            .write(to: fixture.fileURL)

        #expect(fixture.store.load() == .model)
    }

    @Test
    func clearReturnsToModel() throws {
        let fixture = try makeFixture()
        try fixture.store.save(.tryIt)

        try fixture.store.clear()

        #expect(fixture.store.load() == .model)
    }

    @Test
    func checkpointsAdvanceInVisibleFlowOrder() {
        #expect(OnboardingCheckpoint.model.next == .permissions)
        #expect(OnboardingCheckpoint.permissions.next == .tryIt)
        #expect(OnboardingCheckpoint.tryIt.next == .completed)
        #expect(OnboardingCheckpoint.completed.next == nil)
    }

    private func makeFixture() throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent(
            "onboarding-progress.json",
            isDirectory: false
        )
        return Fixture(
            store: OnboardingProgressStore(fileURL: fileURL),
            fileURL: fileURL
        )
    }

    private struct Fixture {
        let store: OnboardingProgressStore
        let fileURL: URL
    }
}
