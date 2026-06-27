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
}
