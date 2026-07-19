import CCTransCore
import Foundation
import StoreKit

enum CctransStoreKitProviderError: LocalizedError {
    case unavailableOutsideAppStore
    case productUnavailable(String)
    case unverifiedTransaction
    case unsupportedPurchaseResult

    var errorDescription: String? {
        switch self {
        case .unavailableOutsideAppStore:
            "StoreKit purchases are only available in the Mac App Store build."
        case let .productUnavailable(productID):
            "The App Store product is unavailable: \(productID)"
        case .unverifiedTransaction:
            "The App Store could not verify this purchase. Please try again."
        case .unsupportedPurchaseResult:
            "The App Store returned an unsupported purchase result."
        }
    }
}

final class CctransAppTransactionProvider: CctransStoreKitProviding, @unchecked Sendable {
    static let shared = CctransAppTransactionProvider()

    private init() {}

    func signedAppTransaction() async -> String? {
        #if MAS_BUILD
        do {
            let result = try await AppTransaction.shared
            guard case .verified = result else {
                print("CCTrans Cloud: StoreKit AppTransaction verification failed.")
                return nil
            }
            let jws = result.jwsRepresentation.trimmingCharacters(in: .whitespacesAndNewlines)
            return jws.isEmpty ? nil : jws
        } catch {
            print("CCTrans Cloud: StoreKit AppTransaction unavailable: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    func appStoreReceipt() async -> String? {
        #if MAS_BUILD
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            print("CCTrans Cloud: App Store receipt URL unavailable.")
            return nil
        }
        do {
            let data = try Data(contentsOf: receiptURL)
            return data.isEmpty ? nil : data.base64EncodedString()
        } catch {
            print("CCTrans Cloud: App Store receipt unavailable: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    func purchase(
        productID: String,
        appAccountToken: UUID?
    ) async throws -> CctransStoreKitPurchaseResult {
        #if MAS_BUILD
        guard CctransStoreKitProductID.all.contains(productID),
              let product = try await Product.products(for: [productID]).first else {
            throw CctransStoreKitProviderError.productUnavailable(productID)
        }
        let options: Set<Product.PurchaseOption> = appAccountToken.map {
            [.appAccountToken($0)]
        } ?? []
        switch try await product.purchase(options: options) {
        case let .success(result):
            return .success(try verifiedTransaction(from: result))
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            throw CctransStoreKitProviderError.unsupportedPurchaseResult
        }
        #else
        throw CctransStoreKitProviderError.unavailableOutsideAppStore
        #endif
    }

    func synchronize() async throws {
        #if MAS_BUILD
        try await AppStore.sync()
        #else
        throw CctransStoreKitProviderError.unavailableOutsideAppStore
        #endif
    }

    func currentEntitlements() async throws -> [CctransStoreKitEntitlementResult] {
        #if MAS_BUILD
        var entitlements: [CctransStoreKitEntitlementResult] = []
        for productID in CctransStoreKitProductID.all {
            guard let result = await Transaction.currentEntitlement(for: productID) else {
                continue
            }
            guard case .verified = result else {
                entitlements.append(.unverified(productID: productID))
                continue
            }
            entitlements.append(.verified(try verifiedTransaction(from: result)))
        }
        return entitlements
        #else
        throw CctransStoreKitProviderError.unavailableOutsideAppStore
        #endif
    }

    func unfinishedTransactions() -> AsyncStream<CctransStoreKitVerifiedTransaction> {
        #if MAS_BUILD
        transactionStream(Transaction.unfinished)
        #else
        AsyncStream { $0.finish() }
        #endif
    }

    func transactionUpdates() -> AsyncStream<CctransStoreKitVerifiedTransaction> {
        #if MAS_BUILD
        transactionStream(Transaction.updates)
        #else
        AsyncStream { $0.finish() }
        #endif
    }

    #if MAS_BUILD
    private func transactionStream(
        _ transactions: Transaction.Transactions
    ) -> AsyncStream<CctransStoreKitVerifiedTransaction> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                for await result in transactions {
                    guard !Task.isCancelled else { break }
                    do {
                        continuation.yield(try verifiedTransaction(from: result))
                    } catch {
                        print("CCTrans Cloud: StoreKit transaction update rejected: \(error.localizedDescription)")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func verifiedTransaction(
        from result: VerificationResult<Transaction>
    ) throws -> CctransStoreKitVerifiedTransaction {
        guard case let .verified(transaction) = result else {
            throw CctransStoreKitProviderError.unverifiedTransaction
        }
        let signedTransaction = result.jwsRepresentation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signedTransaction.isEmpty else {
            throw CctransStoreKitProviderError.unverifiedTransaction
        }
        guard CctransStoreKitProductID.all.contains(transaction.productID) else {
            throw CctransStoreKitProviderError.productUnavailable(transaction.productID)
        }
        return CctransStoreKitVerifiedTransaction(
            id: transaction.id,
            productID: transaction.productID,
            appAccountToken: transaction.appAccountToken,
            signedTransaction: signedTransaction,
            finish: { await transaction.finish() }
        )
    }
    #endif
}
