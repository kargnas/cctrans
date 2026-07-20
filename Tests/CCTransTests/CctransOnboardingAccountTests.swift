import CCTransCore
import Foundation
import Testing

struct CctransOnboardingAccountTests {
    @Test func cloudSelectionControlsInlineVisibility() {
        var state = CctransOnboardingAccountState()

        #expect(state.isVisible == false)
        state.setCloudSelected(true)
        #expect(state.isVisible == true)
        state.setCloudSelected(false)
        #expect(state.isVisible == false)
    }

    @Test func anonymousChoiceAllowsOnboardingToContinue() {
        var state = CctransOnboardingAccountState()
        state.setCloudSelected(true)

        state.continueAnonymously()

        #expect(state.canContinue == true)
        #expect(state.isAnonymous == true)
        #expect(state.account == nil)
    }

    @Test func browserAuthenticationTracksSuccessAndCancellation() {
        var state = CctransOnboardingAccountState()
        state.setCloudSelected(true)
        state.beginAuthentication()
        #expect(state.isLoading == true)

        state.fail(.cancelled)
        #expect(state.failure == .cancelled)
        #expect(state.isLoading == false)

        state.beginAuthentication()
        state.succeed(accountSummary)
        #expect(state.canContinue == true)
        #expect(state.account == accountSummary)
        #expect(state.failure == nil)
    }

    @Test func leavingCloudClearsTransientFailureButKeepsExistingAccount() {
        var state = CctransOnboardingAccountState(account: accountSummary)
        state.setCloudSelected(true)
        state.fail(.request("Try again."))

        state.setCloudSelected(false)

        #expect(state.failure == nil)
        #expect(state.account == accountSummary)
    }

    private var accountSummary: CctransAccountSummary {
        CctransAccountSummary(
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "CCTrans User",
            email: "new@example.com",
            emailVerified: true,
            appleLinked: false,
            plan: .free,
            lifetime: false
        )
    }
}
