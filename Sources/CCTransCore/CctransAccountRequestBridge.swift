import Foundation

public enum CctransAccountRequestAction: Equatable, Sendable {
    case appleLogin
    case logout
    case refresh
    case purchase
    case restore
    case unknown(String)

    public init(rawValue: String) {
        self = switch rawValue {
        case "appleLogin": .appleLogin
        case "logout": .logout
        case "refresh": .refresh
        case "purchase": .purchase
        case "restore": .restore
        default: .unknown(rawValue)
        }
    }
}

public enum CctransAccountActionResponseCode: String, Codable, Sendable {
    case success
    case error
    case notAvailable = "not_available"
}

public struct CctransAccountActionResponse: Codable, Equatable, Sendable {
    public let title: String
    public let message: String
    public let ok: Bool
    public let code: CctransAccountActionResponseCode

    public init(
        title: String,
        message: String,
        ok: Bool,
        code: CctransAccountActionResponseCode
    ) {
        self.title = title
        self.message = message
        self.ok = ok
        self.code = code
    }

    public static func success(title: String, message: String) -> Self {
        Self(title: title, message: message, ok: true, code: .success)
    }

    public static func error(title: String, message: String) -> Self {
        Self(title: title, message: message, ok: false, code: .error)
    }

    public static func notAvailable(title: String, message: String) -> Self {
        Self(title: title, message: message, ok: false, code: .notAvailable)
    }
}

public struct CctransAccountPendingRequest: Equatable, Sendable {
    public let action: CctransAccountRequestAction
    public let nonce: String
    public let requestURL: URL

    public init(action: CctransAccountRequestAction, nonce: String, requestURL: URL) {
        self.action = action
        self.nonce = nonce
        self.requestURL = requestURL
    }
}

public enum CctransAccountRequestFiles {
    private struct Request: Decodable {
        let action: String
        let nonce: String
        let createdAt: Double
    }

    public static func pendingRequests(
        in directoryURL: URL,
        now: Date = Date(),
        staleAfter: TimeInterval = 30
    ) throws -> [CctransAccountPendingRequest] {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let timestamp = now.timeIntervalSince1970

        for url in entries where isResponseFile(url) {
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970
            if timestamp - (modifiedAt ?? 0) > staleAfter {
                try? FileManager.default.removeItem(at: url)
            }
        }

        return entries
            .filter(isRequestFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let request = try? JSONDecoder().decode(Request.self, from: data),
                      isSafeNonce(request.nonce),
                      url.lastPathComponent == "req-\(request.nonce).json",
                      timestamp - request.createdAt <= staleAfter else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return CctransAccountPendingRequest(
                    action: CctransAccountRequestAction(rawValue: request.action),
                    nonce: request.nonce,
                    requestURL: url
                )
            }
    }

    public static func complete(
        _ request: CctransAccountPendingRequest,
        with response: CctransAccountActionResponse,
        in directoryURL: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: request.requestURL.path) else {
            return
        }
        let responseURL = directoryURL.appendingPathComponent(
            "resp-\(request.nonce).json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyAtomicFileWriter.write(encoder.encode(response), to: responseURL)
        do {
            try FileManager.default.removeItem(at: request.requestURL)
        } catch {
            try? FileManager.default.removeItem(at: responseURL)
            throw error
        }
    }

    private static func isRequestFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("req-") && url.pathExtension == "json"
    }

    private static func isResponseFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("resp-") && url.pathExtension == "json"
    }

    private static func isSafeNonce(_ nonce: String) -> Bool {
        !nonce.isEmpty && nonce.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

public struct CctransAccountRequestDispatcher: Sendable {
    public typealias Handler = @MainActor @Sendable () async -> CctransAccountActionResponse
    public typealias StoreKitHandler = @MainActor @Sendable (CctransAccountRequestAction) async -> CctransAccountActionResponse

    private let appleLogin: Handler
    private let logout: Handler
    private let refresh: Handler
    private let storeKit: StoreKitHandler?

    public init(
        appleLogin: @escaping Handler,
        logout: @escaping Handler,
        refresh: @escaping Handler,
        storeKit: StoreKitHandler? = nil
    ) {
        self.appleLogin = appleLogin
        self.logout = logout
        self.refresh = refresh
        self.storeKit = storeKit
    }

    @MainActor
    public func response(for action: CctransAccountRequestAction) async -> CctransAccountActionResponse {
        switch action {
        case .appleLogin:
            await appleLogin()
        case .logout:
            await logout()
        case .refresh:
            await refresh()
        case .purchase:
            await storeKit?(.purchase) ?? .notAvailable(
                title: "Purchase",
                message: "StoreKit purchases are not available yet."
            )
        case .restore:
            await storeKit?(.restore) ?? .notAvailable(
                title: "Restore",
                message: "StoreKit restore is not available yet."
            )
        case let .unknown(action):
            .error(title: "Account", message: "Unknown account action: \(action)")
        }
    }
}
