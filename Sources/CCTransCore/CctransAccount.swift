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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public final class CctransAccountSessionCoordinator: Sendable {
    struct Operation: Equatable, Sendable {
        fileprivate let revision: UInt64
    }

    private let tokenStore: any CctransAccountTokenStore
    private let summaryStore: CctransAccountSummaryStore
    private let state = Mutex(State())

    private struct State: Sendable {
        var revision: UInt64 = 0
    }

    public init(
        tokenStore: any CctransAccountTokenStore,
        summaryStore: CctransAccountSummaryStore
    ) {
        self.tokenStore = tokenStore
        self.summaryStore = summaryStore
    }

    public func loadToken() throws -> String? {
        try state.withLock { _ in
            try normalizedStoredToken()
        }
    }

    public func clearIfTokenMatches(_ token: String) throws {
        try state.withLock { state in
            guard try normalizedStoredToken() == token else {
                return
            }
            state.revision &+= 1
            try clearStoredSession()
        }
    }

    func beginOperation() -> Operation {
        state.withLock { state in
            state.revision &+= 1
            return Operation(revision: state.revision)
        }
    }

    func beginAuthenticatedOperation() throws -> (operation: Operation, token: String?) {
        try state.withLock { state in
            state.revision &+= 1
            return (Operation(revision: state.revision), try normalizedStoredToken())
        }
    }

    func store(
        _ session: CctransAccountSession,
        for operation: Operation
    ) throws -> Bool {
        try state.withLock { state in
            guard operation.revision == state.revision else {
                return false
            }
            try replaceStoredSession(with: session)
            return true
        }
    }

    func store(
        _ summary: CctransAccountSummary,
        for operation: Operation,
        expectedToken: String
    ) throws -> Bool {
        try state.withLock { state in
            guard operation.revision == state.revision,
                  try normalizedStoredToken() == expectedToken else {
                return false
            }
            try summaryStore.save(summary)
            return true
        }
    }

    func clear(
        for operation: Operation,
        expectedToken: String?
    ) throws -> Bool {
        try state.withLock { state in
            guard operation.revision == state.revision,
                  try normalizedStoredToken() == expectedToken else {
                return false
            }
            try clearStoredSession()
            return true
        }
    }

    private func normalizedStoredToken() throws -> String? {
        guard let token = try tokenStore.load() else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : token
    }

    private func replaceStoredSession(with session: CctransAccountSession) throws {
        let previousToken = try tokenStore.load()
        try tokenStore.save(session.token)
        do {
            try summaryStore.save(session.account)
        } catch {
            try restoreToken(previousToken)
            throw error
        }
    }

    private func clearStoredSession() throws {
        let previousSummary = try summaryStore.load()
        try summaryStore.delete()
        do {
            try tokenStore.delete()
        } catch {
            if let previousSummary {
                try summaryStore.save(previousSummary)
            }
            throw error
        }
    }

    private func restoreToken(_ token: String?) throws {
        if let token {
            try tokenStore.save(token)
        } else {
            try tokenStore.delete()
        }
    }
}

public enum CctransAccountAPIErrorCode: String, Codable, Sendable {
    case invalidToken = "invalid_token"
    case invalidCredentials = "invalid_credentials"
    case invalidAppleToken = "invalid_apple_token"
    case accountLinkRequired = "account_link_required"
    case accountAlreadyLinked = "account_already_linked"
    case deviceAlreadyLinked = "device_already_linked"
    case missingAbility = "missing_ability"
    case purchaseAlreadyClaimed = "purchase_already_claimed"
}

public enum CctransAccountError: LocalizedError, Equatable, Sendable {
    case attestUnavailable
    case invalidURL(String)
    case api(status: Int, code: CctransAccountAPIErrorCode?)
    case malformedResponse
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
        case .operationSuperseded:
            "A newer CCTrans account operation replaced this request."
        }
    }
}
