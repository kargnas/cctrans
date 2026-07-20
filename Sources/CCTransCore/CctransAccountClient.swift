import CryptoKit
import Foundation

public actor CctransAccountClient: CctransStoreKitTransactionClaiming {
    public static let defaultBaseURL = "https://kargn.as/v1/cctrans"

    private let session: URLSession
    private let baseURL: String
    private let sessionCoordinator: CctransAccountSessionCoordinator
    private let attestor: (any CctransAttesting)?
    private let devTokenProvider: (@Sendable () -> String?)?
    private let appTransactionProvider: (@Sendable () async -> String?)?
    private let appReceiptProvider: (@Sendable () async -> String?)?

    public init(
        session: URLSession = .shared,
        baseURL: String = defaultBaseURL,
        sessionCoordinator: CctransAccountSessionCoordinator,
        attestor: (any CctransAttesting)? = nil,
        devTokenProvider: (@Sendable () -> String?)? = nil,
        appTransactionProvider: (@Sendable () async -> String?)? = nil,
        appReceiptProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.session = session
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.sessionCoordinator = sessionCoordinator
        self.attestor = attestor
        self.devTokenProvider = devTokenProvider
        self.appTransactionProvider = appTransactionProvider
        self.appReceiptProvider = appReceiptProvider
    }

    package init(
        session: URLSession = .shared,
        baseURL: String = defaultBaseURL,
        tokenStore: any CctransAccountTokenStore,
        summaryStore: CctransAccountSummaryStore,
        lockFileURL: URL,
        attestor: (any CctransAttesting)? = nil,
        devTokenProvider: (@Sendable () -> String?)? = nil,
        appTransactionProvider: (@Sendable () async -> String?)? = nil,
        appReceiptProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.session = session
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.sessionCoordinator = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockFileURL
        )
        self.attestor = attestor
        self.devTokenProvider = devTokenProvider
        self.appTransactionProvider = appTransactionProvider
        self.appReceiptProvider = appReceiptProvider
    }

    public func signInWithOAuth(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        shouldCommit: @escaping @Sendable () -> Bool = { true },
        didCommit: @escaping @Sendable (CctransAccountSession) throws -> Void = { _ in }
    ) async throws -> CctransAccountSession {
        try await authenticate(
            path: "/auth/oauth/token",
            body: [
                "grant_type": "authorization_code",
                "client_id": CctransOAuthAuthorizationRequest.clientID,
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": codeVerifier,
            ],
            shouldCommit: shouldCommit,
            didCommit: didCommit
        )
    }

    public func refresh() async throws -> CctransAccountSummary? {
        let context = try sessionCoordinator.beginAuthenticatedOperation()
        return try await refresh(using: context)
    }

    public func refreshStoreKitAccount(
        expectedAccountUUID: UUID
    ) async throws -> CctransAccountSummary? {
        let context = try sessionCoordinator.beginStoreKitOperation(
            expectedAccountUUID: expectedAccountUUID
        )
        return try await refresh(using: context)
    }

    private func refresh(
        using context: (operation: CctransAccountSessionCoordinator.Operation, token: String?)
    ) async throws -> CctransAccountSummary? {
        guard let token = context.token else {
            guard try sessionCoordinator.clear(
                for: context.operation,
                expectedToken: nil
            ) else {
                throw CctransAccountError.operationSuperseded
            }
            return nil
        }

        var request = try makeRequest(path: "/account", method: "GET")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await applyAppTrust(to: &request)
        let data = try await send(
            request,
            unauthorizedContext: (context.operation, token)
        )
        let response = try decode(AccountResponse.self, from: data)
        guard try sessionCoordinator.store(
            response.account,
            for: context.operation,
            expectedToken: token
        ) else {
            throw CctransAccountError.operationSuperseded
        }
        return response.account
    }

    public func logout() async throws {
        let context = try sessionCoordinator.beginAuthenticatedOperation()
        guard try sessionCoordinator.clear(
            for: context.operation,
            expectedToken: context.token
        ) else {
            throw CctransAccountError.operationSuperseded
        }
        let token = context.token
        guard let token else {
            return
        }

        var request = try makeRequest(path: "/auth/logout", method: "POST")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    public func currentAccountUUID() throws -> UUID? {
        try sessionCoordinator.loadAccountSummary()?.uuid
    }

    public func submitStoreKitTransaction(
        signedTransaction: String,
        expectedAccountUUID: UUID?
    ) async throws -> Bool {
        let signedTransaction = signedTransaction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signedTransaction.isEmpty else {
            throw CctransAccountError.invalidStoreKitTransaction
        }

        let context = try sessionCoordinator.beginStoreKitOperation(
            expectedAccountUUID: expectedAccountUUID
        )
        let isAuthenticated = context.token != nil
        var request = try makeRequest(
            path: isAuthenticated ? "/subscription/claim" : "/subscription/verify",
            method: "POST"
        )
        if let token = context.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        try await applyAppTrust(
            to: &request,
            jsonBody: ["signed_transaction": signedTransaction],
            requiresChallenge: true
        )
        _ = try await send(
            request,
            unauthorizedContext: context.token.map { (context.operation, $0) }
        )

        return isAuthenticated
    }

    private func authenticate(
        path: String,
        body: [String: String],
        shouldCommit: @escaping @Sendable () -> Bool = { true },
        didCommit: @escaping @Sendable (CctransAccountSession) throws -> Void = { _ in }
    ) async throws -> CctransAccountSession {
        let operation = try sessionCoordinator.beginOperation()
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        let response = try decode(SessionResponse.self, from: data)
        let accountSession = CctransAccountSession(token: response.token, account: response.account)
        guard try sessionCoordinator.store(
            accountSession,
            for: operation,
            validation: shouldCommit,
            didCommit: { try didCommit(accountSession) }
        ) else {
            throw CctransAccountError.operationSuperseded
        }
        return accountSession
    }

    private func applyAppTrust(
        to request: inout URLRequest,
        jsonBody: [String: Any]? = nil,
        requiresChallenge: Bool = false
    ) async throws {
        var body = jsonBody ?? Self.jsonObject(from: request.httpBody)
        let devToken = devTokenProvider?()?.nilIfBlank
        let appTransaction = devToken == nil
            ? await appTransactionProvider?()?.nilIfBlank
            : nil
        let appReceipt = devToken == nil && appTransaction == nil
            ? await appReceiptProvider?()?.nilIfBlank
            : nil
        let assertionContext: (attestor: any CctransAttesting, keyID: String)?
        if devToken == nil, appTransaction == nil, appReceipt == nil {
            guard let attestor, attestor.isSupported else {
                throw CctransAccountError.attestUnavailable
            }
            assertionContext = (attestor, try await ensureRegistered(attestor))
        } else {
            assertionContext = nil
        }

        if requiresChallenge || assertionContext != nil {
            body["challenge"] = try await fetchChallenge(
                type: "assert",
                keyID: assertionContext?.keyID
            )
        }
        if let appReceipt {
            body["app_receipt"] = appReceipt
        }
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        if let devToken {
            request.setValue(devToken, forHTTPHeaderField: "X-Cctrans-Dev-Token")
            return
        }
        if let appTransaction {
            request.setValue(appTransaction, forHTTPHeaderField: "X-Cctrans-App-Transaction")
            return
        }
        if appReceipt != nil {
            return
        }
        guard let assertionContext, let encodedBody = request.httpBody else {
            throw CctransAccountError.attestUnavailable
        }
        let assertion = try await assertionContext.attestor.generateAssertion(
            assertionContext.keyID,
            clientDataHash: Data(SHA256.hash(data: encodedBody))
        )
        request.setValue(assertionContext.keyID, forHTTPHeaderField: "X-Cctrans-Key-Id")
        request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Cctrans-Assertion")
    }

    private func ensureRegistered(_ attestor: any CctransAttesting) async throws -> String {
        if let keyID = attestor.loadKeyID() {
            return keyID
        }
        let keyID = try await attestor.generateKey()
        let challenge = try await fetchChallenge(type: "attest", keyID: keyID)
        let attestation = try await attestor.attestKey(
            keyID,
            clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8)))
        )
        var request = try makeRequest(path: "/attest/register", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key_id": keyID,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
        ])
        _ = try await send(request)
        attestor.saveKeyID(keyID)
        return keyID
    }

    private func fetchChallenge(type: String, keyID: String?) async throws -> String {
        var request = try makeRequest(path: "/attest/challenge", method: "POST")
        var body = ["type": type]
        if let keyID, !keyID.isEmpty {
            body["key_id"] = keyID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenge = object["challenge"] as? String,
              !challenge.isEmpty else {
            throw CctransAccountError.malformedResponse
        }
        return challenge
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw CctransAccountError.invalidURL(baseURL + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(
        _ request: URLRequest,
        unauthorizedContext: (operation: CctransAccountSessionCoordinator.Operation, token: String)? = nil
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CctransAccountError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = Self.apiErrorCode(from: data)
            if http.statusCode == 401,
               let unauthorizedContext,
               Self.isAccountAuthenticationFailure(data: data, code: code) {
                guard try sessionCoordinator.clear(
                    for: unauthorizedContext.operation,
                    expectedToken: unauthorizedContext.token
                ) else {
                    throw CctransAccountError.operationSuperseded
                }
            }
            throw CctransAccountError.api(status: http.statusCode, code: code)
        }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CctransAccountError.malformedResponse
        }
    }

    private static func apiErrorCode(from data: Data) -> CctransAccountAPIErrorCode? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let rawValue = object["error"] as? String,
           let code = CctransAccountAPIErrorCode(rawValue: rawValue) {
            return code
        }
        return object["message"] as? String == "Unauthenticated." ? .unauthenticated : nil
    }

    private static func isAccountAuthenticationFailure(
        data: Data,
        code: CctransAccountAPIErrorCode?
    ) -> Bool {
        if code == .invalidToken || code == .unauthenticated {
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["error"] as? String == "unauthenticated"
            || object["message"] as? String == "Unauthenticated."
    }

    private static func jsonObject(from data: Data?) -> [String: Any] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

private struct SessionResponse: Decodable {
    let token: String
    let account: CctransAccountSummary
}

private struct AccountResponse: Decodable {
    let account: CctransAccountSummary
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
