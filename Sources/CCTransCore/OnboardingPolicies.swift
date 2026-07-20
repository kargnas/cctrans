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
    public enum Failure: Equatable, Sendable {
        case cancelled
        case request(String)
    }

    public private(set) var isVisible = false
    public private(set) var isAnonymous = false
    public private(set) var isLoading = false
    public private(set) var account: CctransAccountSummary?
    public private(set) var failure: Failure?

    public init(account: CctransAccountSummary? = nil) {
        self.account = account
    }

    public var canContinue: Bool {
        account != nil || isAnonymous
    }

    public mutating func setCloudSelected(_ selected: Bool) {
        isVisible = selected
        guard !selected else { return }
        failure = nil
        isLoading = false
    }

    public mutating func continueAnonymously() {
        isAnonymous = true
        isLoading = false
        failure = nil
    }

    public mutating func beginAuthentication() {
        isLoading = true
        failure = nil
    }

    public mutating func succeed(_ account: CctransAccountSummary) {
        self.account = account
        isAnonymous = false
        isLoading = false
        failure = nil
    }

    public mutating func fail(_ failure: Failure) {
        self.failure = failure
        isLoading = false
    }

    public mutating func cancelLoading() {
        isLoading = false
    }

    public mutating func cancelAuthentication() {
        isLoading = false
        failure = nil
    }
}
