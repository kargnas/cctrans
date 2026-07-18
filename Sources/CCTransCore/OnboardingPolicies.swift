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
        hadPersistedSettingsAtLaunch: Bool
    ) -> TranslationProvider {
        guard startsAtModel,
              !hasCompletedOnboarding,
              !hadPersistedSettingsAtLaunch else {
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
}

public enum OnboardingCredentialValue {
    public static func isSafe(_ value: String) -> Bool {
        !value.contains("\n") && !value.contains("\r") && !value.contains("\0")
    }
}
