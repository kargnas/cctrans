import CCTransCore
import Foundation
import Security

enum CctransAccountStorage {
    nonisolated static let tokenStore = CctransAccountKeychainStore()
    nonisolated static let summaryStore = CctransAccountSummaryStore(
        fileURL: SharedAppStorage.fileURL("account-summary.json")
    )
    nonisolated static let sessionCoordinator = CctransAccountSessionCoordinator(
        tokenStore: tokenStore,
        summaryStore: summaryStore
    )
}

struct CctransAccountKeychainStore: CctransAccountTokenStore {
    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CctransAccountKeychainError(status)
        }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw CctransAccountKeychainError(errSecDecode)
        }
        return token
    }

    func save(_ token: String) throws {
        guard !token.isEmpty else {
            throw CctransAccountKeychainError(errSecParam)
        }
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CctransAccountKeychainError(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CctransAccountKeychainError(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CctransAccountKeychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CctransAccountCredential.service,
            kSecAttrAccount as String: CctransAccountCredential.account,
            kSecAttrAccessGroup as String: CctransAccountCredential.accessGroup,
        ]
    }
}

private struct CctransAccountKeychainError: LocalizedError {
    let status: OSStatus

    init(_ status: OSStatus) {
        self.status = status
    }

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
    }
}
