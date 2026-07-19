import CCTransCore
import Foundation
import Testing

@Suite(.serialized)
struct CctransStoreKitAccountTests {
    @Test func loggedInPurchasePassesAccountUUIDAndFinishesAfterClaim() async throws {
        let events = StoreKitEventRecorder()
        let transaction = CctransStoreKitVerifiedTransaction(
            id: 1,
            productID: CctransStoreKitProductID.monthly,
            signedTransaction: "signed-monthly",
            finish: { await events.append("finish:signed-monthly") }
        )
        let store = MockStoreKitProvider(purchaseResult: .success(transaction))
        let claimer = MockStoreKitClaimer(events: events, account: storeKitAccountSummary)
        let coordinator = CctransStoreKitAccountCoordinator(store: store, claimer: claimer)

        let outcome = try await coordinator.purchase(appAccountToken: storeKitAccountUUID)

        #expect(await store.lastPurchaseAccountToken == storeKitAccountUUID)
        #expect(await store.lastPurchaseProductID == CctransStoreKitProductID.monthly)
        #expect(outcome == .purchased(account: storeKitAccountSummary))
        #expect(await claimer.expectedAccountUUIDs == [storeKitAccountUUID])
        #expect(await events.values == [
            "claim:signed-monthly", "finish:signed-monthly", "refresh",
        ])
    }

    @Test func anonymousPurchaseOmitsAppAccountToken() async throws {
        let transaction = CctransStoreKitVerifiedTransaction(
            id: 2,
            productID: CctransStoreKitProductID.monthly,
            signedTransaction: "signed-anonymous",
            finish: {}
        )
        let store = MockStoreKitProvider(purchaseResult: .success(transaction))
        let coordinator = CctransStoreKitAccountCoordinator(
            store: store,
            claimer: MockStoreKitClaimer(account: nil)
        )

        _ = try await coordinator.purchase(appAccountToken: nil)

        #expect(await store.lastPurchaseAccountToken == nil)
    }

    @Test func restoreSynchronizesAndRepeatsIdempotentClaims() async throws {
        let events = StoreKitEventRecorder()
        let transactions = [
            CctransStoreKitVerifiedTransaction(
                id: 10,
                productID: CctransStoreKitProductID.yearly,
                signedTransaction: "signed-yearly",
                finish: { await events.append("finish:signed-yearly") }
            ),
            CctransStoreKitVerifiedTransaction(
                id: 11,
                productID: CctransStoreKitProductID.lifetime,
                signedTransaction: "signed-lifetime",
                finish: { await events.append("finish:signed-lifetime") }
            ),
        ]
        let store = MockStoreKitProvider(
            currentEntitlements: transactions.map(CctransStoreKitEntitlementResult.verified)
        )
        let claimer = MockStoreKitClaimer(events: events, account: storeKitAccountSummary)
        let coordinator = CctransStoreKitAccountCoordinator(store: store, claimer: claimer)

        let first = try await coordinator.restore(expectedAccountUUID: storeKitAccountUUID)
        let second = try await coordinator.restore(expectedAccountUUID: storeKitAccountUUID)

        #expect(first == .restored(
            count: 2,
            failedCount: 0,
            retryableCount: 0,
            account: storeKitAccountSummary,
            accountRefreshFailed: false
        ))
        #expect(second == .restored(
            count: 2,
            failedCount: 0,
            retryableCount: 0,
            account: storeKitAccountSummary,
            accountRefreshFailed: false
        ))
        #expect(await store.synchronizeCount == 2)
        #expect(await claimer.signedTransactions == [
            "signed-yearly", "signed-lifetime", "signed-yearly", "signed-lifetime",
        ])
        #expect(await events.values == [
            "claim:signed-yearly", "finish:signed-yearly",
            "claim:signed-lifetime", "finish:signed-lifetime",
            "refresh",
            "claim:signed-yearly", "finish:signed-yearly",
            "claim:signed-lifetime", "finish:signed-lifetime",
            "refresh",
        ])
    }

    @Test func restoreContinuesAfterClaimFailureAndFinishesLaterPurchases() async throws {
        let events = StoreKitEventRecorder()
        let failed = CctransStoreKitVerifiedTransaction(
            id: 12,
            productID: CctransStoreKitProductID.monthly,
            signedTransaction: "signed-failed",
            finish: { await events.append("finish:signed-failed") }
        )
        let restored = CctransStoreKitVerifiedTransaction(
            id: 13,
            productID: CctransStoreKitProductID.lifetime,
            signedTransaction: "signed-restored",
            finish: { await events.append("finish:signed-restored") }
        )
        let store = MockStoreKitProvider(currentEntitlements: [
            .verified(failed),
            .verified(restored),
        ])
        let claimer = MockStoreKitClaimer(
            events: events,
            account: storeKitAccountSummary,
            errorsByTransaction: [
                "signed-failed": .api(status: 409, code: .purchaseAlreadyClaimed),
            ]
        )
        let coordinator = CctransStoreKitAccountCoordinator(store: store, claimer: claimer)

        let outcome = try await coordinator.restore(expectedAccountUUID: storeKitAccountUUID)

        #expect(outcome == .restored(
            count: 1,
            failedCount: 1,
            retryableCount: 1,
            account: storeKitAccountSummary,
            accountRefreshFailed: false
        ))
        #expect(await events.values == [
            "claim:signed-failed",
            "claim:signed-restored", "finish:signed-restored",
            "refresh",
        ])
    }

    @Test func restoreContinuesAfterUnverifiedEntitlement() async throws {
        let events = StoreKitEventRecorder()
        let restored = CctransStoreKitVerifiedTransaction(
            id: 14,
            productID: CctransStoreKitProductID.yearly,
            signedTransaction: "signed-yearly",
            finish: { await events.append("finish:signed-yearly") }
        )
        let store = MockStoreKitProvider(currentEntitlements: [
            .unverified(productID: CctransStoreKitProductID.monthly),
            .verified(restored),
        ])
        let coordinator = CctransStoreKitAccountCoordinator(
            store: store,
            claimer: MockStoreKitClaimer(events: events, account: storeKitAccountSummary)
        )

        let outcome = try await coordinator.restore(expectedAccountUUID: storeKitAccountUUID)

        #expect(outcome == .restored(
            count: 1,
            failedCount: 1,
            retryableCount: 0,
            account: storeKitAccountSummary,
            accountRefreshFailed: false
        ))
        #expect(await events.values == [
            "claim:signed-yearly", "finish:signed-yearly", "refresh",
        ])
    }

    @Test func claimConflictLeavesTransactionUnfinishedForRetry() async throws {
        let events = StoreKitEventRecorder()
        let transaction = CctransStoreKitVerifiedTransaction(
            id: 3,
            productID: CctransStoreKitProductID.monthly,
            signedTransaction: "signed-conflict",
            finish: { await events.append("finish:signed-conflict") }
        )
        let store = MockStoreKitProvider(purchaseResult: .success(transaction))
        let claimer = MockStoreKitClaimer(
            events: events,
            error: CctransAccountError.api(status: 409, code: .purchaseAlreadyClaimed)
        )
        let coordinator = CctransStoreKitAccountCoordinator(store: store, claimer: claimer)

        await #expect(throws: CctransAccountError.api(
            status: 409,
            code: .purchaseAlreadyClaimed
        )) {
            try await coordinator.purchase(appAccountToken: storeKitAccountUUID)
        }

        #expect(await events.values == ["claim:signed-conflict"])
    }

    @Test func pendingAndCancelledPurchasesDoNotClaimTransactions() async throws {
        let pendingClaimer = MockStoreKitClaimer(account: nil)
        let pendingCoordinator = CctransStoreKitAccountCoordinator(
            store: MockStoreKitProvider(purchaseResult: .pending),
            claimer: pendingClaimer
        )
        let cancelledClaimer = MockStoreKitClaimer(account: nil)
        let cancelledCoordinator = CctransStoreKitAccountCoordinator(
            store: MockStoreKitProvider(purchaseResult: .userCancelled),
            claimer: cancelledClaimer
        )

        let pending = try await pendingCoordinator.purchase(appAccountToken: storeKitAccountUUID)
        let cancelled = try await cancelledCoordinator.purchase(appAccountToken: storeKitAccountUUID)

        #expect(pending == .pending)
        #expect(cancelled == .userCancelled)
        #expect(await pendingClaimer.signedTransactions.isEmpty)
        #expect(await cancelledClaimer.signedTransactions.isEmpty)
    }

    @Test func refreshFailureHappensAfterAcceptedTransactionIsFinished() async throws {
        let events = StoreKitEventRecorder()
        let transaction = CctransStoreKitVerifiedTransaction(
            id: 4,
            productID: CctransStoreKitProductID.monthly,
            signedTransaction: "signed-refresh-failure",
            finish: { await events.append("finish:signed-refresh-failure") }
        )
        let claimer = MockStoreKitClaimer(
            events: events,
            account: nil,
            refreshError: URLError(.notConnectedToInternet)
        )
        let coordinator = CctransStoreKitAccountCoordinator(
            store: MockStoreKitProvider(purchaseResult: .success(transaction)),
            claimer: claimer
        )

        await #expect(throws: CctransStoreKitPostClaimRefreshError.self) {
            try await coordinator.purchase(appAccountToken: storeKitAccountUUID)
        }

        #expect(await events.values == [
            "claim:signed-refresh-failure", "finish:signed-refresh-failure", "refresh",
        ])
    }

    @Test func partialRestoreKeepsRetryableTransactionWhenAccountRefreshFails() async throws {
        let events = StoreKitEventRecorder()
        let initiallyFailed = CctransStoreKitVerifiedTransaction(
            id: 20,
            productID: CctransStoreKitProductID.monthly,
            signedTransaction: "signed-retry",
            finish: { await events.append("finish:signed-retry") }
        )
        let restored = CctransStoreKitVerifiedTransaction(
            id: 21,
            productID: CctransStoreKitProductID.yearly,
            signedTransaction: "signed-restored",
            finish: { await events.append("finish:signed-restored") }
        )
        let claimer = MockStoreKitClaimer(
            events: events,
            account: storeKitAccountSummary,
            refreshError: URLError(.notConnectedToInternet),
            errorsByTransaction: [
                "signed-retry": .api(status: 503, code: .notConfigured),
            ],
            failureCountsByTransaction: ["signed-retry": 1],
            refreshFailureCount: 1
        )
        let coordinator = CctransStoreKitAccountCoordinator(
            store: MockStoreKitProvider(currentEntitlements: [
                .verified(initiallyFailed),
                .verified(restored),
            ]),
            claimer: claimer
        )

        let outcome = try await coordinator.restore(expectedAccountUUID: storeKitAccountUUID)
        let retryCompleted = await coordinator.retryPendingWork()

        #expect(outcome == .restored(
            count: 1,
            failedCount: 1,
            retryableCount: 1,
            account: nil,
            accountRefreshFailed: true
        ))
        #expect(retryCompleted)
        #expect(await events.values == [
            "claim:signed-retry",
            "claim:signed-restored", "finish:signed-restored",
            "refresh",
            "claim:signed-retry", "finish:signed-retry",
            "refresh",
        ])
    }
}

private actor MockStoreKitProvider: CctransStoreKitProviding {
    private let purchaseResult: CctransStoreKitPurchaseResult
    private let entitlements: [CctransStoreKitEntitlementResult]
    private(set) var lastPurchaseProductID: String?
    private(set) var lastPurchaseAccountToken: UUID?
    private(set) var synchronizeCount = 0

    init(
        purchaseResult: CctransStoreKitPurchaseResult = .userCancelled,
        currentEntitlements: [CctransStoreKitEntitlementResult] = []
    ) {
        self.purchaseResult = purchaseResult
        self.entitlements = currentEntitlements
    }

    func purchase(productID: String, appAccountToken: UUID?) async throws -> CctransStoreKitPurchaseResult {
        lastPurchaseProductID = productID
        lastPurchaseAccountToken = appAccountToken
        return purchaseResult
    }

    func synchronize() async throws {
        synchronizeCount += 1
    }

    func currentEntitlements() async throws -> [CctransStoreKitEntitlementResult] {
        entitlements
    }
}

private actor MockStoreKitClaimer: CctransStoreKitTransactionClaiming {
    private let events: StoreKitEventRecorder?
    private let account: CctransAccountSummary?
    private let error: CctransAccountError?
    private let refreshError: (any Error)?
    private let errorsByTransaction: [String: CctransAccountError]
    private var remainingFailureCountsByTransaction: [String: Int]
    private var remainingRefreshFailures: Int
    private(set) var signedTransactions: [String] = []
    private(set) var expectedAccountUUIDs: [UUID?] = []

    init(
        events: StoreKitEventRecorder? = nil,
        account: CctransAccountSummary? = nil,
        error: CctransAccountError? = nil,
        refreshError: (any Error)? = nil,
        errorsByTransaction: [String: CctransAccountError] = [:],
        failureCountsByTransaction: [String: Int] = [:],
        refreshFailureCount: Int = .max
    ) {
        self.events = events
        self.account = account
        self.error = error
        self.refreshError = refreshError
        self.errorsByTransaction = errorsByTransaction
        self.remainingFailureCountsByTransaction = failureCountsByTransaction
        self.remainingRefreshFailures = refreshFailureCount
    }

    func submitStoreKitTransaction(
        signedTransaction: String,
        expectedAccountUUID: UUID?
    ) async throws -> Bool {
        signedTransactions.append(signedTransaction)
        expectedAccountUUIDs.append(expectedAccountUUID)
        await events?.append("claim:\(signedTransaction)")
        if let error {
            throw error
        }
        if let transactionError = errorsByTransaction[signedTransaction] {
            let remainingFailures = remainingFailureCountsByTransaction[signedTransaction] ?? .max
            if remainingFailures > 0 {
                if remainingFailures != .max {
                    remainingFailureCountsByTransaction[signedTransaction] = remainingFailures - 1
                }
                throw transactionError
            }
        }
        return expectedAccountUUID != nil
    }

    func refreshStoreKitAccount(
        expectedAccountUUID: UUID
    ) async throws -> CctransAccountSummary? {
        await events?.append("refresh")
        if let refreshError, remainingRefreshFailures > 0 {
            if remainingRefreshFailures != .max {
                remainingRefreshFailures -= 1
            }
            throw refreshError
        }
        return account
    }
}

private actor StoreKitEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private let storeKitAccountUUID = UUID(uuidString: "5D0BBD71-10D3-4F2C-B034-C5860B076E11")!
private let storeKitAccountSummary = CctransAccountSummary(
    uuid: storeKitAccountUUID,
    name: "CCTrans User",
    email: "user@example.com",
    emailVerified: true,
    appleLinked: true,
    plan: .pro,
    source: .storeKit,
    proUntil: Date(timeIntervalSince1970: 1_900_000_000),
    lifetime: false
)
