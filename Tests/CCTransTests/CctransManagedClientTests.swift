import CCTransCore
import CryptoKit
import Foundation
import Testing

/// CCTrans Cloud (kargn.as managed) wire-contract tests.
///
/// The managed auth paths share the SAME REST machinery — same body encoder, same
/// `/translate` endpoint, same response parser. These tests lock that: the only
/// difference is the auth header and whether a challenge is required. That parity is the
/// whole point of the dev token — QA exercises the real engine + paywall, not a divergent stub.
@Suite(.serialized)
struct CctransManagedClientTests {
    // MARK: Dev-token path (QA bypass) — must mirror production exactly bar the auth header

    @Test func devTokenPathSendsTokenHeaderAndNoAssertionAndParsesText() async throws {
        let captured = RequestCapture()
        let client = CctransManagedClient(
            session: makeManagedSession { request in
                captured.record(request)
                if request.url?.path.hasSuffix("/translate") == true {
                    return (200, json(["ok": true, "result": ["kind": "text", "text": "안녕하세요", "imageUrl": NSNull()]]))
                }
                return (404, Data())
            },
            attestor: nil
        )

        let outcome = try await client.translate(
            mode: "text", text: "Hello", imageDataURL: nil, targetCode: "ko", devToken: "cctdev_test"
        )

        #expect(outcome == .success(kind: "text", text: "안녕하세요", imageURL: nil))
        let translate = try #require(captured.request(path: "/translate"))
        // Dev path = real path minus the App Attest auth. Verify the divergence is ONLY that.
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Dev-Token") == "cctdev_test")
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Key-Id") == nil)
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Assertion") == nil)
        let body = try #require(translate.jsonBody)
        #expect(body["mode"] as? String == "text")
        #expect(body["text"] as? String == "Hello")
        #expect(body["target"] as? String == "ko")
        #expect(body["challenge"] == nil) // no challenge on the dev path
        // The dev path must NOT touch the attest endpoints at all.
        #expect(captured.request(path: "/attest/challenge") == nil)
        #expect(captured.request(path: "/attest/register") == nil)
    }

    @Test func devTokenPathParsesPaywallBlockVerbatim() async throws {
        // A quota/cap block is HTTP 200 + ok:false (NOT an error status). The client renders
        // the server's display copy and never sees the numbers behind it (§3 secret boundary).
        let client = CctransManagedClient(
            session: makeManagedSession { _ in
                (200, json([
                    "ok": false,
                    "action": "paywall",
                    "display": ["title": "Unlock unlimited translation", "body": "You have reached the free usage limit.", "cta": "Go Pro"],
                ]))
            },
            attestor: nil
        )

        let outcome = try await client.translate(
            mode: "text", text: "Hello", imageDataURL: nil, targetCode: "ko", devToken: "cctdev_test"
        )

        #expect(outcome == .blocked(
            action: "paywall",
            title: "Unlock unlimited translation",
            body: "You have reached the free usage limit.",
            cta: "Go Pro"
        ))
    }

    @Test func upstreamFailureMapsToUpstreamError() async throws {
        // 502 = engine failure, not a quota block. Distinct case so callers can retry.
        let client = CctransManagedClient(
            session: makeManagedSession { _ in (502, json(["ok": false, "error": "upstream"])) },
            attestor: nil
        )

        await #expect(throws: CctransManagedError.upstream) {
            try await client.translate(mode: "text", text: "Hi", imageDataURL: nil, targetCode: "ko", devToken: "cctdev_test")
        }
    }

    @Test func noDevTokenAndUnsupportedAttestThrowsAttestUnavailable() async throws {
        // Unsigned dev build with no dev token: surface, do not silently swap providers.
        let client = CctransManagedClient(
            session: makeManagedSession { _ in (200, Data()) },
            attestor: MockAttestor(isSupported: false)
        )

        await #expect(throws: CctransManagedError.attestUnavailable) {
            try await client.translate(mode: "text", text: "Hi", imageDataURL: nil, targetCode: "ko", devToken: nil)
        }
    }

    @Test func appTransactionPathSendsJWSHeaderWithoutChallenge() async throws {
        let captured = RequestCapture()
        let client = CctransManagedClient(
            session: makeManagedSession { request in
                captured.record(request)
                if request.url?.path.hasSuffix("/translate") == true {
                    return (200, json(["ok": true, "result": ["kind": "text", "text": "앱거래", "imageUrl": NSNull()]]))
                }
                return (404, Data())
            },
            attestor: MockAttestor(isSupported: false),
            appTransactionProvider: { "signed-app-transaction-jws" }
        )

        let outcome = try await client.translate(
            mode: "text", text: "Hello", imageDataURL: nil, targetCode: "ko", devToken: nil
        )

        #expect(outcome == .success(kind: "text", text: "앱거래", imageURL: nil))
        let translate = try #require(captured.request(path: "/translate"))
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-App-Transaction") == "signed-app-transaction-jws")
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Key-Id") == nil)
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Assertion") == nil)
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Dev-Token") == nil)
        #expect(captured.request(path: "/attest/challenge") == nil)
        let body = try #require(translate.jsonBody)
        #expect(body["mode"] as? String == "text")
        #expect(body["text"] as? String == "Hello")
        #expect(body["target"] as? String == "ko")
        #expect(body["challenge"] == nil)
    }

    // MARK: App Attest path — production. Orchestrates challenge → register → assert → translate.

    @Test func attestPathRegistersOnceThenSignsBodyWithAssertion() async throws {
        let captured = RequestCapture()
        let attestor = MockAttestor(isSupported: true, keyID: "KEYID-base64")
        let client = CctransManagedClient(
            session: makeManagedSession { request in
                captured.record(request)
                let path = request.url?.path ?? ""
                if path.hasSuffix("/attest/challenge") {
                    // Echo a challenge that encodes the requested type so the test can assert
                    // the assert-challenge (not the attest one) ends up in the translate body.
                    let type = (request.jsonBody?["type"] as? String) ?? "?"
                    return (200, json(["challenge": "chal-\(type)"]))
                }
                if path.hasSuffix("/attest/register") {
                    return (200, json(["ok": true]))
                }
                if path.hasSuffix("/translate") {
                    return (200, json(["ok": true, "result": ["kind": "text", "text": "서명됨", "imageUrl": NSNull()]]))
                }
                return (404, Data())
            },
            attestor: attestor
        )

        let outcome = try await client.translate(
            mode: "text", text: "Hello", imageDataURL: nil, targetCode: "ko", devToken: nil
        )

        #expect(outcome == .success(kind: "text", text: "서명됨", imageURL: nil))

        // Registration happened exactly once and the keyID was persisted.
        #expect(attestor.savedKeyID == "KEYID-base64")
        let register = try #require(captured.request(path: "/attest/register"))
        let registerBody = try #require(register.jsonBody)
        #expect(registerBody["key_id"] as? String == "KEYID-base64")
        #expect(registerBody["challenge"] as? String == "chal-attest")
        #expect(registerBody["attestation"] as? String == Data("ATTEST".utf8).base64EncodedString())

        // The translate request carries the assertion auth + the assert challenge in the body.
        let translate = try #require(captured.request(path: "/translate"))
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Key-Id") == "KEYID-base64")
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Assertion") == Data("ASSERT".utf8).base64EncodedString())
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Dev-Token") == nil)
        let translateBody = try #require(translate.httpBodyData)
        let bodyObject = try #require(try JSONSerialization.jsonObject(with: translateBody) as? [String: Any])
        #expect(bodyObject["challenge"] as? String == "chal-assert")

        // The assertion signed SHA256 of the EXACT bytes that were transmitted — this is what
        // stops a cheap-path body from being swapped for an expensive one server-side.
        #expect(attestor.lastAssertionHash == Data(SHA256.hash(data: translateBody)))
    }

    @Test func attestPathReusesStoredKeyIDWithoutReRegistering() async throws {
        let captured = RequestCapture()
        let attestor = MockAttestor(isSupported: true, keyID: "NEW", storedKeyID: "EXISTING")
        let client = CctransManagedClient(
            session: makeManagedSession { request in
                captured.record(request)
                let path = request.url?.path ?? ""
                if path.hasSuffix("/attest/challenge") { return (200, json(["challenge": "chal-assert"])) }
                if path.hasSuffix("/translate") {
                    return (200, json(["ok": true, "result": ["kind": "text", "text": "ok", "imageUrl": NSNull()]]))
                }
                return (404, Data())
            },
            attestor: attestor
        )

        _ = try await client.translate(mode: "text", text: "Hi", imageDataURL: nil, targetCode: "ko", devToken: nil)

        // A registered install skips attest/register entirely and never burns a new key.
        #expect(captured.request(path: "/attest/register") == nil)
        #expect(attestor.generateKeyCalled == false)
        let translate = try #require(captured.request(path: "/translate"))
        #expect(translate.value(forHTTPHeaderField: "X-Cctrans-Key-Id") == "EXISTING")
    }

    // MARK: Through TranslationService — provider dispatch + blocked → error mapping

    @Test func translationServiceRoutesManagedProviderThroughDevToken() async throws {
        let client = CctransManagedClient(
            session: makeManagedSession { _ in
                (200, json(["ok": true, "result": ["kind": "text", "text": "서비스 경유", "imageUrl": NSNull()]]))
            },
            attestor: nil
        )
        let service = TranslationService(managedClient: client)

        let result = try await service.translateText(
            "Hello",
            settings: TranslatorSettings(provider: .kargnasManaged),
            credentials: TranslatorCredentials(openRouterAPIKey: nil, huggingFaceToken: nil, cctransDevToken: "cctdev_test")
        )

        #expect(result.text == "서비스 경유")
        #expect(result.providerTitle == "CCTrans Cloud")
    }

    @Test func translationServiceMapsBlockedToManagedBlockedError() async throws {
        let client = CctransManagedClient(
            session: makeManagedSession { _ in
                (200, json([
                    "ok": false, "action": "paywall",
                    "display": ["title": "T", "body": "B", "cta": "C"],
                ]))
            },
            attestor: nil
        )
        let service = TranslationService(managedClient: client)

        await #expect(throws: TranslationError.managedBlocked(title: "T", body: "B", cta: "C")) {
            try await service.translateText(
                "Hello",
                settings: TranslatorSettings(provider: .kargnasManaged),
                credentials: TranslatorCredentials(openRouterAPIKey: nil, huggingFaceToken: nil, cctransDevToken: "cctdev_test")
            )
        }
    }
}

// MARK: - Test doubles

/// Mock App Attest provider. No DeviceCheck — returns canned blobs and records what it was
/// asked to sign so tests can assert the client signed the exact request body.
private final class MockAttestor: CctransAttesting, @unchecked Sendable {
    let isSupported: Bool
    private let keyID: String
    private let lock = NSLock()
    private var _storedKeyID: String?
    private(set) var savedKeyID: String?
    private(set) var lastAssertionHash: Data?
    private(set) var generateKeyCalled = false

    init(isSupported: Bool, keyID: String = "KEYID", storedKeyID: String? = nil) {
        self.isSupported = isSupported
        self.keyID = keyID
        self._storedKeyID = storedKeyID
    }

    func loadKeyID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _storedKeyID
    }

    func saveKeyID(_ keyID: String) {
        lock.lock(); defer { lock.unlock() }
        savedKeyID = keyID
        _storedKeyID = keyID
    }

    func generateKey() async throws -> String {
        // Lock via a sync helper: NSLock.lock()/unlock() are unavailable directly in an
        // async context under Swift 6 strict concurrency.
        markGenerateKeyCalled()
        return keyID
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("ATTEST".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        recordAssertionHash(clientDataHash)
        return Data("ASSERT".utf8)
    }

    private func markGenerateKeyCalled() {
        lock.lock(); generateKeyCalled = true; lock.unlock()
    }

    private func recordAssertionHash(_ hash: Data) {
        lock.lock(); lastAssertionHash = hash; lock.unlock()
    }
}

/// Thread-safe record of requests the stub saw, for header/body assertions after the call.
private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock(); requests.append(request); lock.unlock()
    }

    func request(path suffix: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last { $0.url?.path.hasSuffix(suffix) == true }
    }
}

private func makeManagedSession(
    handler: @escaping @Sendable (URLRequest) -> (Int, Data)
) -> URLSession {
    CctransStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CctransStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private final class CctransStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "kargn.as"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession often moves the body onto `httpBodyStream`; read whichever is present.
    var httpBodyData: Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    var jsonBody: [String: Any]? {
        guard let httpBodyData else { return nil }
        return (try? JSONSerialization.jsonObject(with: httpBodyData)) as? [String: Any]
    }
}
