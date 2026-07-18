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

@Suite
struct OnboardingTryItGateTests {
    @Test
    func ignoresRequestStartedBeforeTryIt() {
        var gate = OnboardingTryItGate()

        gate.noteRequestStarted(id: 7, isEligible: false)

        #expect(gate.acceptSuccess(id: 7) == false)
    }

    @Test
    func acceptsOnlyTheLatestEligibleRequest() {
        var gate = OnboardingTryItGate()
        gate.noteRequestStarted(id: 7, isEligible: true)
        gate.noteRequestStarted(id: 8, isEligible: true)

        #expect(gate.acceptSuccess(id: 7) == false)
        #expect(gate.acceptSuccess(id: 8) == true)
        #expect(gate.acceptSuccess(id: 8) == false)
    }

    @Test
    func ineligibleRequestCancelsEarlierEligibility() {
        var gate = OnboardingTryItGate()
        gate.noteRequestStarted(id: 7, isEligible: true)

        gate.noteRequestStarted(id: 8, isEligible: false)

        #expect(gate.acceptSuccess(id: 7) == false)
        #expect(gate.acceptSuccess(id: 8) == false)
    }

    @Test
    func deactivationRejectsInflightSuccess() {
        var gate = OnboardingTryItGate()
        gate.noteRequestStarted(id: 7, isEligible: true)

        gate.deactivate()

        #expect(gate.acceptSuccess(id: 7) == false)
    }
}

@Suite
struct OnboardingPermissionReadinessTests {
    @Test
    func directBuildAcceptsEitherKeyboardPermission() {
        #expect(OnboardingPermissionReadiness.isReady(
            screenRecording: true,
            inputMonitoring: true,
            accessibility: false,
            requiresKeyboardPermission: true
        ))
        #expect(OnboardingPermissionReadiness.isReady(
            screenRecording: true,
            inputMonitoring: false,
            accessibility: true,
            requiresKeyboardPermission: true
        ))
    }

    @Test
    func directBuildStillRequiresScreenRecording() {
        #expect(OnboardingPermissionReadiness.isReady(
            screenRecording: false,
            inputMonitoring: true,
            accessibility: true,
            requiresKeyboardPermission: true
        ) == false)
    }

    @Test
    func storeBuildOnlyRequiresScreenRecording() {
        #expect(OnboardingPermissionReadiness.isReady(
            screenRecording: true,
            inputMonitoring: false,
            accessibility: false,
            requiresKeyboardPermission: false
        ))
    }
}

@Suite
struct OnboardingProviderPolicyTests {
    @Test
    func freshModelStepDefaultsToApple() {
        #expect(OnboardingProviderPolicy.initialProvider(
            current: .localHyMT2,
            startsAtModel: true,
            hasCompletedOnboarding: false,
            hadPersistedSettingsAtLaunch: false
        ) == .appleTranslation)
    }

    @Test
    func upgradedInstallPreservesItsProvider() {
        #expect(OnboardingProviderPolicy.initialProvider(
            current: .openRouter,
            startsAtModel: true,
            hasCompletedOnboarding: false,
            hadPersistedSettingsAtLaunch: true
        ) == .openRouter)
    }

    @Test
    func resumedFlowPreservesCommittedProvider() {
        #expect(OnboardingProviderPolicy.initialProvider(
            current: .localHyMT2,
            startsAtModel: false,
            hasCompletedOnboarding: false,
            hadPersistedSettingsAtLaunch: false
        ) == .localHyMT2)
    }
}

@Suite
struct OnboardingCompletionMarkerPolicyTests {
    @Test
    func clearsMarkerOnlyAfterSharedSettingsAreDurable() {
        #expect(OnboardingCompletionMarkerPolicy.shouldClearMarker(
            hasCompletedOnboarding: true,
            sharedSettingsWriteSucceeded: true
        ))
        #expect(OnboardingCompletionMarkerPolicy.shouldClearMarker(
            hasCompletedOnboarding: true,
            sharedSettingsWriteSucceeded: false
        ) == false)
        #expect(OnboardingCompletionMarkerPolicy.shouldClearMarker(
            hasCompletedOnboarding: false,
            sharedSettingsWriteSucceeded: true
        ) == false)
    }
}

@Suite
struct OnboardingCredentialValueTests {
    @Test
    func acceptsOrdinarySingleLineSecret() {
        #expect(OnboardingCredentialValue.isSafe("sk-or-v1_example-123"))
    }

    @Test
    func rejectsEnvironmentLineInjection() {
        #expect(OnboardingCredentialValue.isSafe("secret\nHF_TOKEN=injected") == false)
        #expect(OnboardingCredentialValue.isSafe("secret\rHF_TOKEN=injected") == false)
        #expect(OnboardingCredentialValue.isSafe("secret\0suffix") == false)
    }
}
