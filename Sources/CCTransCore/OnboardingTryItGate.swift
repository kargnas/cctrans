public struct OnboardingTryItGate: Sendable {
    private var eligibleRequestID: Int?

    public init() {}

    public mutating func noteRequestStarted(id: Int, isEligible: Bool) {
        eligibleRequestID = isEligible ? id : nil
    }

    public mutating func acceptSuccess(id: Int) -> Bool {
        guard eligibleRequestID == id else { return false }
        eligibleRequestID = nil
        return true
    }

    public mutating func deactivate() {
        eligibleRequestID = nil
    }
}
