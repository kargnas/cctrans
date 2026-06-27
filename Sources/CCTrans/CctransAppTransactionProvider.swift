import Foundation
import StoreKit

final class CctransAppTransactionProvider: @unchecked Sendable {
    static let shared = CctransAppTransactionProvider()

    private init() {}

    func signedAppTransaction() async -> String? {
        #if MAS_BUILD
        do {
            let transaction = try await AppTransaction.shared
            let jws = transaction.jwsRepresentation.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
