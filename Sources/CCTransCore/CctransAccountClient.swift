import CryptoKit
import Foundation

public final class CctransAccountClient: @unchecked Sendable {
    public static let defaultBaseURL = "https://kargn.as/v1/cctrans"

    private let session: URLSession
    private let baseURL: String
    private let tokenStore: any CctransAccountTokenStore
    private let summaryStore: CctransAccountSummaryStore
    private let attestor: (any CctransAttesting)?
    private let devTokenProvider: (@Sendable () -> String?)?
    private let appTransactionProvider: (@Sendable () async -> String?)?
    private let appReceiptProvider: (@Sendable () async -> String?)?

    public init(
        session: URLSession = .shared,
        baseURL: String = defaultBaseURL,
        tokenStore: any CctransAccountTokenStore,
        summaryStore: CctransAccountSummaryStore,
        attestor: (any CctransAttesting)? = nil,
        devTokenProvider: (@Sendable () -> String?)? = nil,
        appTransactionProvider: (@Sendable () async -> String?)? = nil,
        appReceiptProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.session = session
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.tokenStore = tokenStore
        self.summaryStore = summaryStore
        self.attestor = attestor
        self.devTokenProvider = devTokenProvider
        self.appTransactionProvider = appTransactionProvider
        self.appReceiptProvider = appReceiptProvider
    }

    public func register(
        name: String,
        email: String,
        password: String,
        passwordConfirmation: String
    ) async throws -> CctransAccountSession {
        try await authenticate(path: "/auth/register", body: [
            "name": name,
            "email": email,
            "password": password,
            "password_confirmation": passwordConfirmation,
        ])
    }

    public func login(email: String, password: String) async throws -> CctransAccountSession {
        try await authenticate(path: "/auth/login", body: [
            "email": email,
            "password": password,
        ])
    }

    public func signInWithApple(
        identityToken: String,
        nonce: String,
        name: String? = nil
    ) async throws -> CctransAccountSession {
        var body = ["identity_token": identityToken, "nonce": nonce]
        if let name, !name.isEmpty {
            body["name"] = name
        }
        return try await authenticate(path: "/auth/apple", body: body)
    }

    public func refresh() async throws -> CctransAccountSummary? {
        guard let token = try tokenStore.load()?.nilIfBlank else {
            try summaryStore.delete()
            return nil
        }

        var request = try makeRequest(path: "/account", method: "GET")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await applyAppTrust(to: &request)
        let data = try await send(request, clearsSessionOnUnauthorized: true)
        let response = try decode(AccountResponse.self, from: data)
        try summaryStore.save(response.account)
        return response.account
    }

    public func logout() async throws {
        let token = try tokenStore.load()?.nilIfBlank
        defer { clearLocalSession() }
        guard let token else {
            return
        }

        var request = try makeRequest(path: "/auth/logout", method: "POST")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await send(request, clearsSessionOnUnauthorized: true)
    }

    private func authenticate(path: String, body: [String: String]) async throws -> CctransAccountSession {
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request, clearsSessionOnUnauthorized: false)
        let response = try decode(SessionResponse.self, from: data)
        let accountSession = CctransAccountSession(token: response.token, account: response.account)
        do {
            try tokenStore.save(response.token)
            try summaryStore.save(response.account)
        } catch {
            clearLocalSession()
            throw error
        }
        return accountSession
    }

    private func applyAppTrust(to request: inout URLRequest) async throws {
        if let devToken = devTokenProvider?()?.nilIfBlank {
            request.setValue(devToken, forHTTPHeaderField: "X-Cctrans-Dev-Token")
            return
        }
        if let appTransaction = await appTransactionProvider?()?.nilIfBlank {
            request.setValue(appTransaction, forHTTPHeaderField: "X-Cctrans-App-Transaction")
            return
        }
        if let appReceipt = await appReceiptProvider?()?.nilIfBlank {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["app_receipt": appReceipt])
            return
        }
        guard let attestor, attestor.isSupported else {
            throw CctransAccountError.attestUnavailable
        }

        let keyID = try await ensureRegistered(attestor)
        let challenge = try await fetchChallenge(type: "assert", keyID: keyID)
        let body = try JSONSerialization.data(withJSONObject: ["challenge": challenge])
        let assertion = try await attestor.generateAssertion(
            keyID,
            clientDataHash: Data(SHA256.hash(data: body))
        )
        request.setValue(keyID, forHTTPHeaderField: "X-Cctrans-Key-Id")
        request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Cctrans-Assertion")
        request.httpBody = body
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
        _ = try await send(request, clearsSessionOnUnauthorized: false)
        attestor.saveKeyID(keyID)
        return keyID
    }

    private func fetchChallenge(type: String, keyID: String) async throws -> String {
        var request = try makeRequest(path: "/attest/challenge", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": type, "key_id": keyID])
        let data = try await send(request, clearsSessionOnUnauthorized: false)
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

    private func send(_ request: URLRequest, clearsSessionOnUnauthorized: Bool) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CctransAccountError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = Self.apiErrorCode(from: data)
            if http.statusCode == 401, clearsSessionOnUnauthorized {
                clearLocalSession()
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

    private func clearLocalSession() {
        try? tokenStore.delete()
        try? summaryStore.delete()
    }

    private static func apiErrorCode(from data: Data) -> CctransAccountAPIErrorCode? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object["error"] as? String else {
            return nil
        }
        return CctransAccountAPIErrorCode(rawValue: rawValue)
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
