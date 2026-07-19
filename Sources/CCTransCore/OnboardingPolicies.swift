public enum OnboardingPermissionReadiness {
    public static func isReady(
        screenRecording: Bool,
        inputMonitoring: Bool,
        accessibility: Bool,
        requiresKeyboardPermission: Bool
    ) -> Bool {
        guard screenRecording else { return false }
        return !requiresKeyboardPermission || inputMonitoring || accessibility
    }
}

public enum OnboardingProviderPolicy {
    public static func initialProvider(
        current: TranslationProvider,
        startsAtModel: Bool,
        hasCompletedOnboarding: Bool,
        hadExistingAppStateAtLaunch: Bool
    ) -> TranslationProvider {
        guard startsAtModel,
              !hasCompletedOnboarding,
              !hadExistingAppStateAtLaunch else {
            return current
        }
        return .appleTranslation
    }
}

public enum OnboardingCompletionMarkerPolicy {
    public static func shouldClearMarker(
        hasCompletedOnboarding: Bool,
        sharedSettingsWriteSucceeded: Bool
    ) -> Bool {
        hasCompletedOnboarding && sharedSettingsWriteSucceeded
    }

    public static func canDismiss(sharedSettingsWriteSucceeded: Bool) -> Bool {
        sharedSettingsWriteSucceeded
    }
}

public enum OnboardingCredentialValue {
    public static func isSafe(_ value: String) -> Bool {
        !value.contains("\n") && !value.contains("\r") && !value.contains("\0")
    }
}

public struct CctransOnboardingAccountState: Equatable, Sendable {
    public enum EmailMode: String, CaseIterable, Sendable {
        case login
        case register
    }

    public enum Failure: Equatable, Sendable {
        case validation(String)
        case cancelled
        case accountLinkRequired
        case request(String)
    }

    public struct EmailSubmission: Equatable, Sendable {
        public let mode: EmailMode
        public let email: String
        public let password: String
    }

    public private(set) var isVisible = false
    public private(set) var isShowingEmailForm = false
    public private(set) var isAnonymous = false
    public private(set) var isLoading = false
    public private(set) var account: CctransAccountSummary?
    public private(set) var failure: Failure?
    public var emailMode: EmailMode = .login
    public var email = ""
    public var password = ""

    public init(account: CctransAccountSummary? = nil) {
        self.account = account
    }

    public var canContinue: Bool {
        account != nil || isAnonymous
    }

    public mutating func setCloudSelected(_ selected: Bool) {
        isVisible = selected
        guard !selected else { return }
        resetSensitiveState()
        isShowingEmailForm = false
        isLoading = false
    }

    public mutating func showEmailForm() {
        isShowingEmailForm = true
        failure = nil
    }

    public mutating func hideEmailForm() {
        resetSensitiveState()
        isShowingEmailForm = false
    }

    public mutating func selectEmailMode(_ mode: EmailMode) {
        emailMode = mode
        resetSensitiveState()
    }

    public mutating func continueAnonymously() {
        isAnonymous = true
        isShowingEmailForm = false
        isLoading = false
        resetSensitiveState()
    }

    public mutating func beginAppleAuthentication() {
        isLoading = true
        failure = nil
    }

    public mutating func beginEmailSubmission() -> EmailSubmission? {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            failure = .validation("Enter a valid email address.")
            return nil
        }
        guard password.count >= 8 else {
            failure = .validation("Password must be at least 8 characters.")
            return nil
        }
        isLoading = true
        failure = nil
        return EmailSubmission(mode: emailMode, email: normalizedEmail, password: password)
    }

    public mutating func succeed(_ account: CctransAccountSummary) {
        self.account = account
        isAnonymous = false
        isShowingEmailForm = false
        isLoading = false
        failure = nil
        password = ""
    }

    public mutating func fail(_ failure: Failure) {
        self.failure = failure
        isLoading = false
    }

    public mutating func cancelLoading() {
        isLoading = false
    }

    private mutating func resetSensitiveState() {
        password = ""
        failure = nil
    }
}
