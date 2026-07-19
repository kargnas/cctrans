import CCTransCore
import Foundation
import Testing

@Suite(.serialized)
struct CctransAccountTests {
    @Test func loginStoresTokenSeparatelyFromSummary() async throws {
        let tokenStore = MockAccountTokenStore()
        let summaryURL = temporarySummaryURL()
        let summaryStore = CctransAccountSummaryStore(fileURL: summaryURL)
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                #expect(request.url?.path.hasSuffix("/auth/login") == true)
                return .response(200, accountSessionJSON(token: "secret-sanctum-token"))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            appTransactionProvider: { "signed-app-transaction" }
        )

        let session = try await client.login(email: "user@example.com", password: "password")

        #expect(session.token == "secret-sanctum-token")
        #expect(try tokenStore.load() == "secret-sanctum-token")
        #expect(try summaryStore.load()?.uuid == accountUUID)
        let storedJSON = try String(contentsOf: summaryURL, encoding: .utf8)
        #expect(!storedJSON.contains("secret-sanctum-token"))
        #expect(!storedJSON.contains("token"))
    }

    @Test func summaryPreservesAccountDisplayContractWithoutToken() throws {
        let summary = try JSONDecoder().decode(
            CctransAccountSummary.self,
            from: json([
                "uuid": accountUUID.uuidString.lowercased(),
                "name": "CCTrans User",
                "email": "user@example.com",
                "email_verified": true,
                "apple_linked": true,
                "plan": "pro",
                "source": "storekit",
                "pro_until": "2030-01-02T03:04:05Z",
                "lifetime": false,
                "syncing": true,
            ])
        )

        #expect(summary.uuid == accountUUID)
        #expect(summary.plan == .pro)
        #expect(summary.source == .storeKit)
        #expect(summary.expiresAt != nil)
        #expect(summary.lifetime == false)
        #expect(summary.syncing == true)
    }

    @Test func refreshSendsBearerAndStoresLatestSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        let captured = AccountRequestCapture()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                captured.record(request)
                return .response(200, accountSummaryJSON(plan: "lifetime", lifetime: true))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            appTransactionProvider: { "signed-app-transaction" }
        )

        let summary = try #require(try await client.refresh())

        #expect(summary.plan == .lifetime)
        #expect(summary.lifetime)
        let request = try #require(captured.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stored-token")
        #expect(request.value(forHTTPHeaderField: "X-Cctrans-App-Transaction") == "signed-app-transaction")
        #expect(try summaryStore.load() == summary)
    }

    @Test func unauthorizedRefreshClearsTokenAndSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "expired-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(401, json(["ok": false, "error": "invalid_token"]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            appTransactionProvider: { "signed-app-transaction" }
        )

        await #expect(throws: CctransAccountError.api(status: 401, code: .invalidToken)) {
            try await client.refresh()
        }

        #expect(try tokenStore.load() == nil)
        #expect(try summaryStore.load() == nil)
    }

    @Test func networkFailureKeepsLastSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let client = CctransAccountClient(
            session: makeAccountSession { _ in .failure(URLError(.notConnectedToInternet)) },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            appTransactionProvider: { "signed-app-transaction" }
        )

        await #expect(throws: URLError.self) {
            try await client.refresh()
        }

        #expect(try tokenStore.load() == "stored-token")
        #expect(try summaryStore.load() == accountSummary)
    }

    @Test func logoutAlwaysClearsLocalSession() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let captured = AccountRequestCapture()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                captured.record(request)
                return .response(200, json(["ok": true]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore
        )

        try await client.logout()

        #expect(captured.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer stored-token")
        #expect(try tokenStore.load() == nil)
        #expect(try summaryStore.load() == nil)
    }
}

private let accountUUID = UUID(uuidString: "5D0BBD71-10D3-4F2C-B034-C5860B076E11")!
private let accountSummary = CctransAccountSummary(
    uuid: accountUUID,
    name: "CCTrans User",
    email: "user@example.com",
    emailVerified: true,
    appleLinked: false,
    plan: .pro,
    source: .stripe,
    proUntil: Date(timeIntervalSince1970: 1_900_000_000),
    lifetime: false,
    syncing: false
)

private final class MockAccountTokenStore: CctransAccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func save(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

private enum AccountStubResult {
    case response(Int, Data)
    case failure(Error)
}

private final class AccountRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }
}

private func makeAccountSession(
    handler: @escaping @Sendable (URLRequest) -> AccountStubResult
) -> URLSession {
    CctransAccountStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CctransAccountStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class CctransAccountStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> AccountStubResult)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "kargn.as"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.handler?(request) ?? .response(500, Data()) {
        case let .response(status, data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func accountSessionJSON(token: String) -> Data {
    json([
        "ok": true,
        "token": token,
        "account": accountObject(plan: "pro", lifetime: false),
    ])
}

private func accountSummaryJSON(plan: String, lifetime: Bool) -> Data {
    json(["ok": true, "account": accountObject(plan: plan, lifetime: lifetime)])
}

private func accountObject(plan: String, lifetime: Bool) -> [String: Any] {
    [
        "uuid": accountUUID.uuidString.lowercased(),
        "name": "CCTrans User",
        "email": "user@example.com",
        "email_verified": true,
        "apple_linked": false,
        "plan": plan,
        "pro_until": lifetime ? NSNull() : "2030-01-02T03:04:05Z",
        "lifetime": lifetime,
    ]
}

private func temporarySummaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cctrans-account-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("account-summary.json", isDirectory: false)
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}
