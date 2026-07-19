import Foundation

public enum CctransStoreKitProductID {
    public static let monthly = "as.kargn.cctrans.pro.monthly"
    public static let yearly = "as.kargn.cctrans.pro.yearly"
    public static let lifetime = "as.kargn.cctrans.pro.lifetime"
    public static let defaultPurchase = monthly
    public static let all = [monthly, yearly, lifetime]
}

public struct CctransStoreKitVerifiedTransaction: Sendable {
    public let id: UInt64
    public let productID: String
    public let appAccountToken: UUID?
    public let signedTransaction: String
    private let finishHandler: @Sendable () async -> Void

    public init(
        id: UInt64,
        productID: String,
        appAccountToken: UUID? = nil,
        signedTransaction: String,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.productID = productID
        self.appAccountToken = appAccountToken
        self.signedTransaction = signedTransaction
        self.finishHandler = finish
    }

    public func finish() async {
        await finishHandler()
    }
}

public enum CctransStoreKitPurchaseResult: Sendable {
    case success(CctransStoreKitVerifiedTransaction)
    case pending
    case userCancelled
}

public enum CctransStoreKitEntitlementResult: Sendable {
    case verified(CctransStoreKitVerifiedTransaction)
    case unverified(productID: String)
}

public struct CctransStoreKitEntitlementError: LocalizedError, Equatable, Sendable {
    public let productID: String

    public init(productID: String) {
        self.productID = productID
    }

    public var errorDescription: String? {
        "The App Store could not verify the entitlement for \(productID)."
    }
}

public protocol CctransStoreKitProviding: Sendable {
    func purchase(
        productID: String,
        appAccountToken: UUID?
    ) async throws -> CctransStoreKitPurchaseResult
    func synchronize() async throws
    func currentEntitlements() async throws -> [CctransStoreKitEntitlementResult]
    func unfinishedTransactions() -> AsyncStream<CctransStoreKitVerifiedTransaction>
    func transactionUpdates() -> AsyncStream<CctransStoreKitVerifiedTransaction>
}

public extension CctransStoreKitProviding {
    func unfinishedTransactions() -> AsyncStream<CctransStoreKitVerifiedTransaction> {
        AsyncStream { $0.finish() }
    }

    func transactionUpdates() -> AsyncStream<CctransStoreKitVerifiedTransaction> {
        AsyncStream { $0.finish() }
    }
}

public protocol CctransStoreKitTransactionClaiming: Sendable {
    func submitStoreKitTransaction(
        signedTransaction: String,
        expectedAccountUUID: UUID?
    ) async throws -> Bool
    func refreshStoreKitAccount(
        expectedAccountUUID: UUID
    ) async throws -> CctransAccountSummary?
}

public struct CctransStoreKitPostClaimRefreshError: LocalizedError, @unchecked Sendable {
    public let underlyingError: any Error

    public init(underlyingError: any Error) {
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        "The App Store purchase was accepted, but the CCTrans account status could not be refreshed: \(underlyingError.localizedDescription)"
    }
}

public enum CctransStoreKitActionOutcome: Equatable, Sendable {
    case purchased(account: CctransAccountSummary?)
    case restored(
        count: Int,
        failedCount: Int,
        retryableCount: Int,
        account: CctransAccountSummary?,
        accountRefreshFailed: Bool
    )
    case pending
    case userCancelled
}

public actor CctransStoreKitAccountCoordinator {
    private struct PendingRestore: Sendable {
        let transaction: CctransStoreKitVerifiedTransaction
        let expectedAccountUUID: UUID?
    }

    private let store: any CctransStoreKitProviding
    private let claimer: any CctransStoreKitTransactionClaiming
    private let purchaseProductID: String
    private var pendingRestores: [UInt64: PendingRestore] = [:]
    private var pendingAccountRefreshUUID: UUID?

    public init(
        store: any CctransStoreKitProviding,
        claimer: any CctransStoreKitTransactionClaiming,
        purchaseProductID: String = CctransStoreKitProductID.defaultPurchase
    ) {
        self.store = store
        self.claimer = claimer
        self.purchaseProductID = purchaseProductID
    }

    public func purchase(appAccountToken: UUID?) async throws -> CctransStoreKitActionOutcome {
        switch try await store.purchase(
            productID: purchaseProductID,
            appAccountToken: appAccountToken
        ) {
        case let .success(transaction):
            let account = try await synchronize(
                transaction: transaction,
                expectedAccountUUID: appAccountToken
            )
            return .purchased(account: account)
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        }
    }

    public func restore(
        expectedAccountUUID: UUID?
    ) async throws -> CctransStoreKitActionOutcome {
        try await store.synchronize()
        let entitlements = try await store.currentEntitlements()
        var shouldRefreshAccount = false
        var restoredCount = 0
        var failedCount = 0
        var retryableCount = 0
        var firstError: (any Error)?
        for entitlement in entitlements {
            do {
                switch entitlement {
                case let .verified(transaction):
                    shouldRefreshAccount = try await claimAndFinish(
                        transaction,
                        expectedAccountUUID: expectedAccountUUID
                    ) || shouldRefreshAccount
                    restoredCount += 1
                case let .unverified(productID):
                    throw CctransStoreKitEntitlementError(productID: productID)
                }
            } catch {
                failedCount += 1
                firstError = firstError ?? error
                if case let .verified(transaction) = entitlement {
                    pendingRestores[transaction.id] = PendingRestore(
                        transaction: transaction,
                        expectedAccountUUID: expectedAccountUUID
                    )
                    retryableCount += 1
                }
            }
        }
        if restoredCount == 0, let firstError {
            throw firstError
        }
        let account: CctransAccountSummary?
        let accountRefreshFailed: Bool
        do {
            account = try await refreshAccount(
                ifNeeded: shouldRefreshAccount,
                expectedAccountUUID: expectedAccountUUID
            )
            accountRefreshFailed = false
        } catch is CctransStoreKitPostClaimRefreshError {
            account = nil
            accountRefreshFailed = true
        }
        return .restored(
            count: restoredCount,
            failedCount: failedCount,
            retryableCount: retryableCount,
            account: account,
            accountRefreshFailed: accountRefreshFailed
        )
    }

    public func synchronize(
        transaction: CctransStoreKitVerifiedTransaction,
        expectedAccountUUID: UUID?
    ) async throws -> CctransAccountSummary? {
        let shouldRefreshAccount = try await claimAndFinish(
            transaction,
            expectedAccountUUID: expectedAccountUUID
        )
        return try await refreshAccount(
            ifNeeded: shouldRefreshAccount,
            expectedAccountUUID: expectedAccountUUID
        )
    }

    public func retryPendingWork() async -> Bool {
        for (id, pending) in Array(pendingRestores) {
            do {
                let shouldRefreshAccount = try await claimAndFinish(
                    pending.transaction,
                    expectedAccountUUID: pending.expectedAccountUUID
                )
                if shouldRefreshAccount, let expectedAccountUUID = pending.expectedAccountUUID {
                    pendingAccountRefreshUUID = expectedAccountUUID
                }
                pendingRestores.removeValue(forKey: id)
            } catch {
                continue
            }
        }

        if let expectedAccountUUID = pendingAccountRefreshUUID {
            do {
                _ = try await claimer.refreshStoreKitAccount(
                    expectedAccountUUID: expectedAccountUUID
                )
                if pendingAccountRefreshUUID == expectedAccountUUID {
                    pendingAccountRefreshUUID = nil
                }
            } catch {
                return false
            }
        }

        return pendingRestores.isEmpty
    }

    private func claimAndFinish(
        _ transaction: CctransStoreKitVerifiedTransaction,
        expectedAccountUUID: UUID?
    ) async throws -> Bool {
        let shouldRefreshAccount = try await claimer.submitStoreKitTransaction(
            signedTransaction: transaction.signedTransaction,
            expectedAccountUUID: expectedAccountUUID
        )
        await transaction.finish()
        pendingRestores.removeValue(forKey: transaction.id)
        return shouldRefreshAccount
    }

    private func refreshAccount(
        ifNeeded shouldRefreshAccount: Bool,
        expectedAccountUUID: UUID?
    ) async throws -> CctransAccountSummary? {
        guard shouldRefreshAccount, let expectedAccountUUID else {
            return nil
        }
        do {
            let account = try await claimer.refreshStoreKitAccount(
                expectedAccountUUID: expectedAccountUUID
            )
            if pendingAccountRefreshUUID == expectedAccountUUID {
                pendingAccountRefreshUUID = nil
            }
            return account
        } catch {
            pendingAccountRefreshUUID = expectedAccountUUID
            throw CctransStoreKitPostClaimRefreshError(underlyingError: error)
        }
    }
}
