import CryptoKit
import Foundation
import Synchronization

public enum CctransAccountCredential {
    public static let service = "as.kargn.cctrans.account"
    public static let account = "sanctum-token"
    public static let accessGroup = "6YQH3QFFK8.as.kargn.cctrans"
}

public protocol CctransAccountTokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

public enum CctransAccountPlan: String, Codable, Sendable {
    case free
    case pro
    case lifetime
}

public enum CctransAccountEntitlementSource: String, Codable, Sendable {
    case storeKit = "storekit"
    case stripe
}

public struct CctransAccountSummary: Codable, Equatable, Sendable {
    public let uuid: UUID
    public let name: String
    public let email: String
    public let emailVerified: Bool
    public let appleLinked: Bool
    public let plan: CctransAccountPlan
    public let source: CctransAccountEntitlementSource?
    public let proUntil: Date?
    public let lifetime: Bool
    public let syncing: Bool

    public var expiresAt: Date? {
        lifetime ? nil : proUntil
    }

    public init(
        uuid: UUID,
        name: String,
        email: String,
        emailVerified: Bool,
        appleLinked: Bool,
        plan: CctransAccountPlan,
        source: CctransAccountEntitlementSource? = nil,
        proUntil: Date? = nil,
        lifetime: Bool,
        syncing: Bool = false
    ) {
        self.uuid = uuid
        self.name = name
        self.email = email
        self.emailVerified = emailVerified
        self.appleLinked = appleLinked
        self.plan = plan
        self.source = source
        self.proUntil = proUntil
        self.lifetime = lifetime
        self.syncing = syncing
    }

    public func withSyncing(_ syncing: Bool) -> Self {
        Self(
            uuid: uuid,
            name: name,
            email: email,
            emailVerified: emailVerified,
            appleLinked: appleLinked,
            plan: plan,
            source: source,
            proUntil: proUntil,
            lifetime: lifetime,
            syncing: syncing
        )
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case email
        case emailVerified = "email_verified"
        case appleLinked = "apple_linked"
        case plan
        case source
        case proUntil = "pro_until"
        case lifetime
        case syncing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decode(String.self, forKey: .email)
        emailVerified = try container.decode(Bool.self, forKey: .emailVerified)
        appleLinked = try container.decode(Bool.self, forKey: .appleLinked)
        plan = try container.decode(CctransAccountPlan.self, forKey: .plan)
        source = try container.decodeIfPresent(CctransAccountEntitlementSource.self, forKey: .source)
        if let value = try container.decodeIfPresent(String.self, forKey: .proUntil) {
            proUntil = try Self.parseDate(value, codingPath: decoder.codingPath)
        } else {
            proUntil = nil
        }
        lifetime = try container.decode(Bool.self, forKey: .lifetime)
        syncing = try container.decodeIfPresent(Bool.self, forKey: .syncing) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(emailVerified, forKey: .emailVerified)
        try container.encode(appleLinked, forKey: .appleLinked)
        try container.encode(plan, forKey: .plan)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(proUntil?.ISO8601Format(), forKey: .proUntil)
        try container.encode(lifetime, forKey: .lifetime)
        try container.encode(syncing, forKey: .syncing)
    }

    private static func parseDate(_ value: String, codingPath: [any CodingKey]) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(value) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "Invalid account expiry date."
        ))
    }
}

public struct CctransAccountSession: Equatable, Sendable {
    public let token: String
    public let account: CctransAccountSummary

    public init(token: String, account: CctransAccountSummary) {
        self.token = token
        self.account = account
    }
}

public struct CctransAccountSummaryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> CctransAccountSummary? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(CctransAccountSummary.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ summary: CctransAccountSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyAtomicFileWriter.write(encoder.encode(summary), to: fileURL)
    }

    public func delete() throws {
        try OwnerOnlyAtomicFileWriter.removeIfExists(at: fileURL)
    }
}

public final class CctransAccountSessionCoordinator: Sendable {
    struct Operation: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private let tokenStore: any CctransAccountTokenStore
    private let summaryStore: CctransAccountSummaryStore
    private let fileLock: CctransAccountFileLock
    private let generationFileURL: URL
    private let transactionFileURL: URL
    private let state = Mutex(())

    public init(
        tokenStore: any CctransAccountTokenStore,
        summaryStore: CctransAccountSummaryStore,
        lockFileURL: URL
    ) {
        self.tokenStore = tokenStore
        self.summaryStore = summaryStore
        self.fileLock = CctransAccountFileLock(fileURL: lockFileURL)
        generationFileURL = lockFileURL.deletingLastPathComponent()
            .appendingPathComponent("account-session.generation", isDirectory: false)
        transactionFileURL = lockFileURL.deletingLastPathComponent()
            .appendingPathComponent("account-session-transaction.json", isDirectory: false)
    }

    public func loadToken() throws -> String? {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                return try normalizedStoredToken()
            }
        }
    }

    public func loadAccountSummary() throws -> CctransAccountSummary? {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                guard try normalizedStoredToken() != nil else {
                    return nil
                }
                return try summaryStore.load()
            }
        }
    }

    public func clearIfTokenMatches(_ token: String) throws {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                guard try normalizedStoredToken() == token else {
                    return
                }
                _ = try advanceGeneration()
                try clearStoredSession()
            }
        }
    }

    func beginOperation() throws -> Operation {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                return Operation(generation: try advanceGeneration())
            }
        }
    }

    func beginAuthenticatedOperation() throws -> (operation: Operation, token: String?) {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                return (
                    Operation(generation: try advanceGeneration()),
                    try normalizedStoredToken()
                )
            }
        }
    }

    func beginStoreKitOperation(
        expectedAccountUUID: UUID?
    ) throws -> (operation: Operation, token: String?) {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                let token = try normalizedStoredToken()
                if token == nil {
                    guard expectedAccountUUID == nil else {
                        throw CctransAccountError.storeKitAccountChanged
                    }
                } else {
                    guard let currentAccountUUID = try summaryStore.load()?.uuid,
                          currentAccountUUID == expectedAccountUUID else {
                        throw CctransAccountError.storeKitAccountChanged
                    }
                }
                return (
                    Operation(generation: try currentGeneration()),
                    token
                )
            }
        }
    }

    func store(
        _ session: CctransAccountSession,
        for operation: Operation,
        validation: () throws -> Bool = { true },
        didCommit: () throws -> Void = {}
    ) throws -> Bool {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                guard try currentGeneration() == operation.generation,
                      try validation() else {
                    return false
                }
                try replaceStoredSession(with: session, didCommit: didCommit)
                return true
            }
        }
    }

    func store(
        _ summary: CctransAccountSummary,
        for operation: Operation,
        expectedToken: String
    ) throws -> Bool {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                guard try currentGeneration() == operation.generation,
                      try normalizedStoredToken() == expectedToken else {
                    return false
                }
                try summaryStore.save(summary)
                return true
            }
        }
    }

    func clear(
        for operation: Operation,
        expectedToken: String?
    ) throws -> Bool {
        try state.withLock { _ in
            try fileLock.withExclusiveLock {
                try recoverPendingTransaction()
                guard try currentGeneration() == operation.generation,
                      try normalizedStoredToken() == expectedToken else {
                    return false
                }
                try clearStoredSession()
                return true
            }
        }
    }

    private func normalizedStoredToken() throws -> String? {
        guard let token = try tokenStore.load() else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : token
    }

    private func replaceStoredSession(
        with session: CctransAccountSession,
        didCommit: () throws -> Void
    ) throws {
        let previousToken = try normalizedStoredToken()
        let previousSummary = try summaryStore.load()
        try saveTransaction(.replace(
            tokenSHA256: tokenSHA256(session.token),
            account: session.account,
            previousTokenSHA256: previousToken.map(tokenSHA256),
            previousAccount: previousSummary
        ))
        do {
            try tokenStore.save(session.token)
            try summaryStore.save(session.account)
            try didCommit()
            try deleteTransaction()
        } catch {
            let primaryError = error
            do {
                try restoreToken(previousToken)
                try restoreSummary(previousSummary)
                try deleteTransaction()
            } catch {
                throw CctransAccountRecoveryError(primary: primaryError, rollback: error)
            }
            throw primaryError
        }
    }

    private func clearStoredSession() throws {
        let previousToken = try normalizedStoredToken()
        let previousSummary = try summaryStore.load()
        try saveTransaction(.clear(
            previousTokenSHA256: previousToken.map(tokenSHA256),
            previousAccount: previousSummary
        ))
        do {
            try tokenStore.delete()
            try summaryStore.delete()
            try deleteTransaction()
        } catch {
            let primaryError = error
            do {
                try restoreToken(previousToken)
                try restoreSummary(previousSummary)
                try deleteTransaction()
            } catch {
                throw CctransAccountRecoveryError(primary: primaryError, rollback: error)
            }
            throw primaryError
        }
    }

    private func recoverPendingTransaction() throws {
        guard FileManager.default.fileExists(atPath: transactionFileURL.path) else {
            return
        }
        let transaction = try JSONDecoder().decode(
            CctransAccountSessionTransaction.self,
            from: Data(contentsOf: transactionFileURL)
        )
        let storedTokenSHA256 = try normalizedStoredToken().map(tokenSHA256)
        switch transaction {
        case let .replace(tokenSHA256, account, previousTokenSHA256, previousAccount):
            if storedTokenSHA256 == tokenSHA256 {
                try summaryStore.save(account)
            } else if storedTokenSHA256 == previousTokenSHA256 {
                try restoreSummary(previousAccount)
            } else {
                throw CctransAccountTransactionConflictError()
            }
        case let .clear(previousTokenSHA256, previousAccount):
            if storedTokenSHA256 == nil {
                try summaryStore.delete()
            } else if storedTokenSHA256 == previousTokenSHA256 {
                try restoreSummary(previousAccount)
            } else {
                throw CctransAccountTransactionConflictError()
            }
        }
        try deleteTransaction()
    }

    private func saveTransaction(_ transaction: CctransAccountSessionTransaction) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyAtomicFileWriter.write(encoder.encode(transaction), to: transactionFileURL)
    }

    private func deleteTransaction() throws {
        try OwnerOnlyAtomicFileWriter.removeIfExists(at: transactionFileURL)
    }

    private func restoreToken(_ token: String?) throws {
        if let token {
            try tokenStore.save(token)
        } else {
            try tokenStore.delete()
        }
    }

    private func restoreSummary(_ summary: CctransAccountSummary?) throws {
        if let summary {
            try summaryStore.save(summary)
        } else {
            try summaryStore.delete()
        }
    }

    private func tokenSHA256(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func advanceGeneration() throws -> UInt64 {
        let next = try currentGeneration() &+ 1
        var encoded = next.littleEndian
        let data = withUnsafeBytes(of: &encoded) { Data($0) }
        try OwnerOnlyAtomicFileWriter.write(data, to: generationFileURL)
        return next
    }

    private func currentGeneration() throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: generationFileURL.path) else {
            return 0
        }
        let data = try Data(contentsOf: generationFileURL)
        guard data.count == MemoryLayout<UInt64>.size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var encoded: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &encoded) { destination in
            data.copyBytes(to: destination)
        }
        return UInt64(littleEndian: encoded)
    }
}

private enum CctransAccountSessionTransaction: Codable {
    case replace(
        tokenSHA256: String,
        account: CctransAccountSummary,
        previousTokenSHA256: String?,
        previousAccount: CctransAccountSummary?
    )
    case clear(previousTokenSHA256: String?, previousAccount: CctransAccountSummary?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case tokenSHA256 = "token_sha256"
        case account
        case previousTokenSHA256 = "previous_token_sha256"
        case previousAccount = "previous_account"
    }

    private enum Kind: String, Codable {
        case replace
        case clear
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .replace:
            self = try .replace(
                tokenSHA256: container.decode(String.self, forKey: .tokenSHA256),
                account: container.decode(CctransAccountSummary.self, forKey: .account),
                previousTokenSHA256: container.decodeIfPresent(
                    String.self,
                    forKey: .previousTokenSHA256
                ),
                previousAccount: container.decodeIfPresent(
                    CctransAccountSummary.self,
                    forKey: .previousAccount
                )
            )
        case .clear:
            self = try .clear(
                previousTokenSHA256: container.decodeIfPresent(
                    String.self,
                    forKey: .previousTokenSHA256
                ),
                previousAccount: container.decodeIfPresent(
                    CctransAccountSummary.self,
                    forKey: .previousAccount
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .replace(tokenSHA256, account, previousTokenSHA256, previousAccount):
            try container.encode(Kind.replace, forKey: .kind)
            try container.encode(tokenSHA256, forKey: .tokenSHA256)
            try container.encode(account, forKey: .account)
            try container.encodeIfPresent(previousTokenSHA256, forKey: .previousTokenSHA256)
            try container.encodeIfPresent(previousAccount, forKey: .previousAccount)
        case let .clear(previousTokenSHA256, previousAccount):
            try container.encode(Kind.clear, forKey: .kind)
            try container.encodeIfPresent(previousTokenSHA256, forKey: .previousTokenSHA256)
            try container.encodeIfPresent(previousAccount, forKey: .previousAccount)
        }
    }
}

private struct CctransAccountTransactionConflictError: LocalizedError {
    var errorDescription: String? {
        "Account session transaction does not match the stored token."
    }
}

private struct CctransAccountRecoveryError: LocalizedError {
    let primary: any Error
    let rollback: any Error

    var errorDescription: String? {
        "Account session update failed: \(primary.localizedDescription). Recovery also failed: \(rollback.localizedDescription)."
    }
}

public enum CctransAccountAPIErrorCode: String, Codable, Sendable {
    case unauthenticated
    case invalidToken = "invalid_token"
    case invalidCredentials = "invalid_credentials"
    case invalidAppleToken = "invalid_apple_token"
    case accountLinkRequired = "account_link_required"
    case accountAlreadyLinked = "account_already_linked"
    case deviceAlreadyLinked = "device_already_linked"
    case missingAbility = "missing_ability"
    case purchaseAlreadyClaimed = "purchase_already_claimed"
    case purchaseNotActive = "purchase_not_active"
    case appAccountTokenMismatch = "app_account_token_mismatch"
    case invalidTransaction = "invalid_transaction"
    case notConfigured = "not_configured"
}

public enum CctransAccountError: LocalizedError, Equatable, Sendable {
    case attestUnavailable
    case invalidURL(String)
    case api(status: Int, code: CctransAccountAPIErrorCode?)
    case malformedResponse
    case invalidStoreKitTransaction
    case storeKitAccountChanged
    case operationSuperseded

    public var errorDescription: String? {
        switch self {
        case .attestUnavailable:
            "CCTrans account refresh requires an App Store transaction, receipt, App Attest, or dev token."
        case let .invalidURL(url):
            "Invalid CCTrans account URL: \(url)"
        case let .api(status, code):
            "CCTrans account request failed with HTTP \(status)\(code.map { ": \($0.rawValue)" } ?? "")."
        case .malformedResponse:
            "CCTrans account returned an unexpected response."
        case .invalidStoreKitTransaction:
            "StoreKit returned an empty signed transaction."
        case .storeKitAccountChanged:
            "The signed-in CCTrans account changed during the App Store operation."
        case .operationSuperseded:
            "A newer CCTrans account operation replaced this request."
        }
    }
}
