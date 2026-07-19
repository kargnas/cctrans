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

    @Test func successfulAuthenticationKeepsAccountSummaryAndAllowsContinue() {
        var state = CctransOnboardingAccountState()
        state.setCloudSelected(true)
        state.showEmailForm()
        state.email = "new@example.com"
        state.password = "password-1234"
        _ = state.beginEmailSubmission()

        state.succeed(accountSummary(emailVerified: false))

        #expect(state.canContinue == true)
        #expect(state.account?.email == "new@example.com")
        #expect(state.account?.emailVerified == false)
        #expect(state.password.isEmpty)
        #expect(state.failure == nil)
    }

    @Test func requestErrorKeepsEmailFormVisible() {
        var state = CctransOnboardingAccountState()
        state.setCloudSelected(true)
        state.showEmailForm()
        state.email = "user@example.com"
        state.password = "password-1234"
        _ = state.beginEmailSubmission()

        state.fail(.request("The request timed out."))

        #expect(state.isShowingEmailForm == true)
        #expect(state.canContinue == false)
        #expect(state.failure == .request("The request timed out."))
        #expect(state.isLoading == false)
    }

    @Test func appleCancelAndAccountConflictStayDistinct() {
        var state = CctransOnboardingAccountState()
        state.setCloudSelected(true)

        state.beginAppleAuthentication()
        state.fail(.cancelled)
        #expect(state.failure == .cancelled)

        state.beginAppleAuthentication()
        state.fail(.accountLinkRequired)
        #expect(state.failure == .accountLinkRequired)
        #expect(state.canContinue == false)
    }

    @Test func cancelledAppleAttemptCanRetryImmediately() {
        var state = CctransOnboardingAccountState()
        state.setCloudSelected(true)

        state.beginAppleAuthentication()
        state.cancelAuthentication(hideEmailForm: false)
        #expect(state.isLoading == false)
        #expect(state.canContinue == false)

        state.beginAppleAuthentication()
        #expect(state.isLoading == true)
        #expect(state.failure == nil)
    }

    @Test func hidingEmailFormWhileLoadingClearsTransientStateAndKeepsAccount() {
        let summary = accountSummary(emailVerified: true)
        var state = CctransOnboardingAccountState(account: summary)
        state.setCloudSelected(true)
        state.showEmailForm()
        state.email = "user@example.com"
        state.password = "secret-password"
        _ = state.beginEmailSubmission()
        state.fail(.request("Try again."))
        state.password = "retry-password"
        _ = state.beginEmailSubmission()

        state.hideEmailForm()

        #expect(state.isShowingEmailForm == false)
        #expect(state.isLoading == false)
        #expect(state.password.isEmpty)
        #expect(state.failure == nil)
        #expect(state.account == summary)
        #expect(state.email == "user@example.com")
    }

    @Test func switchingModeOrLeavingCloudResetsSensitiveStateOnly() {
        let summary = accountSummary(emailVerified: true)
        var state = CctransOnboardingAccountState(account: summary)
        state.setCloudSelected(true)
        state.showEmailForm()
        state.email = "user@example.com"
        state.password = "secret-password"
        state.fail(.request("Try again."))

        state.selectEmailMode(.register)
        #expect(state.email == "user@example.com")
        #expect(state.password.isEmpty)
        #expect(state.failure == nil)

        state.password = "another-secret"
        state.fail(.request("Still failing."))
        state.setCloudSelected(false)
        #expect(state.password.isEmpty)
        #expect(state.failure == nil)
        #expect(state.account == summary)
    }

    private func accountSummary(emailVerified: Bool) -> CctransAccountSummary {
        CctransAccountSummary(
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "CCTrans User",
            email: "new@example.com",
            emailVerified: emailVerified,
            appleLinked: false,
            plan: .free,
            lifetime: false
        )
    }
}
