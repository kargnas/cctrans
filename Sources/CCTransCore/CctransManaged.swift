import Foundation
import CryptoKit

/// Native App Attest bridge. `CCTransCore` stays platform-light, so native
/// `DCAppAttestService` implementations are injected from the app shell (this mirrors
/// how `AppleTranslationBacking` injects the on-device translation host). The HTTP
/// orchestration (challenge → register → assert round-trips) lives in
/// `CctransManagedClient`; this protocol exposes only the Secure-Enclave primitives
/// plus keyID persistence, so the client is unit-testable with a mock attestor.
public protocol CctransAttesting: Sendable {
    /// Whether App Attest is usable on this device + build. False on unsigned dev
    /// builds and on Macs without a Secure Enclave; the dev-token path covers those.
    var isSupported: Bool { get }
    /// Previously registered keyID (Apple's base64 key identifier), or nil before
    /// the first successful `/attest/register`.
    func loadKeyID() -> String?
    /// Persist the keyID after `/attest/register` succeeds. Without persistence every
    /// launch would re-attest (burning an attestation + a server registration).
    func saveKeyID(_ keyID: String)
    /// `DCAppAttestService.generateKey()` → opaque base64 keyID.
    func generateKey() async throws -> String
    /// `DCAppAttestService.attestKey(_:clientDataHash:)`. `clientDataHash` must be
    /// `SHA256(attest challenge bytes)`; returns the CBOR attestationObject.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    /// `DCAppAttestService.generateAssertion(_:clientDataHash:)`. `clientDataHash` must
    /// be `SHA256(exact request body bytes)`; returns the CBOR assertion.
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// The two shapes `/translate` can return (the client never learns *why* — §3 secret
/// boundary). Either a translation, or a quota/cap block carrying only display copy.
public enum CctransManagedOutcome: Sendable, Equatable {
    /// Server returned a translation. `kind` is `"text"` or `"image"`.
    case success(kind: String, text: String, imageURL: String?)
    /// Server blocked at a quota/cap boundary. The client renders the server's copy
    /// verbatim and never sees the numbers. `cta` is informational until in-app
    /// purchase ships (payment is deferred for the free-only launch).
    case blocked(action: String, title: String, body: String, cta: String)
}

public enum CctransManagedError: LocalizedError, Sendable, Equatable {
    /// No dev token and native App Attest is unavailable, so the device cannot be
    /// proven. Surfaced (not silently swapped) so the user can pick another provider.
    case attestUnavailable
    case invalidURL(String)
    case httpStatus(Int, String)
    case upstream
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .attestUnavailable:
            "CCTrans Cloud needs an App Store build or a dev token to verify this device. Choose another provider, or set a dev token for testing."
        case let .invalidURL(url):
            "Invalid CCTrans Cloud URL: \(url)"
        case let .httpStatus(status, body):
            "CCTrans Cloud request failed with HTTP \(status): \(body)"
        case .upstream:
            "CCTrans Cloud translation engine is temporarily unavailable. Try again."
        case let .malformedResponse(body):
            "CCTrans Cloud returned an unexpected response: \(body)"
        }
    }
}

/// Thin client for the kargn.as managed translation API (`/v1/cctrans`). It owns ONLY
/// the wire protocol — every limit, cost, and threshold lives server-side (§3). Two
/// auth paths:
///   - dev token (`X-Cctrans-Dev-Token`): build automation / QA. No challenge or
///     assertion; the server skips App Attest when its gate is on. Used by unsigned
///     dev builds so the full path can be exercised before a signed build exists.
///   - App Attest (`X-Cctrans-Key-Id` + `X-Cctrans-Assertion`): the production path on
///     platforms where App Attest is an accepted store entitlement. Each request body
///     is signed, so a cheap-path body cannot be swapped for an expensive one.
///   - StoreKit AppTransaction (`X-Cctrans-App-Transaction`): the production path for
///     native macOS App Store builds, where ASC rejects the App Attest entitlement.
public final class CctransManagedClient: @unchecked Sendable {
    public static let defaultBaseURL = "https://kargn.as/v1/cctrans"

    private let session: URLSession
    private let baseURL: String
    private let attestor: (any CctransAttesting)?
    private let appTransactionProvider: (@Sendable () async -> String?)?

    public init(
        session: URLSession = .shared,
        baseURL: String = defaultBaseURL,
        attestor: (any CctransAttesting)? = nil,
        appTransactionProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.session = session
        // Normalize so `baseURL + "/translate"` never produces a double slash.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.attestor = attestor
        self.appTransactionProvider = appTransactionProvider
    }

    /// Send a single translation. `mode` is `"text"`, `"vision"`, or `"image"`;
    /// `targetCode` is a language code (e.g. `"ko"`) — the server maps it to a label.
    public func translate(
        mode: String,
        text: String?,
        imageDataURL: String?,
        targetCode: String,
        devToken: String?
    ) async throws -> CctransManagedOutcome {
        if let devToken, !devToken.isEmpty {
            // Dev/QA bypass. The body mirrors the real wire shape (minus challenge) so
            // the engine + paywall paths are exercised identically to production.
            let body = try encodeBody(challenge: nil, mode: mode, text: text, image: imageDataURL, target: targetCode)
            var request = try makeRequest(path: "/translate")
            request.setValue(devToken, forHTTPHeaderField: "X-Cctrans-Dev-Token")
            request.httpBody = body
            return try await sendTranslate(request)
        }

        if let appTransaction = await appTransactionProvider?(), !appTransaction.isEmpty {
            let body = try encodeBody(challenge: nil, mode: mode, text: text, image: imageDataURL, target: targetCode)
            var request = try makeRequest(path: "/translate")
            request.setValue(appTransaction, forHTTPHeaderField: "X-Cctrans-App-Transaction")
            request.httpBody = body
            return try await sendTranslate(request)
        }

        guard let attestor, attestor.isSupported else {
            throw CctransManagedError.attestUnavailable
        }

        let keyID = try await ensureRegistered(attestor)
        let challenge = try await fetchChallenge(type: "assert", keyID: keyID)
        // The assertion signs the EXACT bytes we transmit, and the challenge must be
        // inside them. Encode once, sign that buffer, send the identical buffer — the
        // server re-hashes the raw received body, so any divergence fails verification.
        let body = try encodeBody(challenge: challenge, mode: mode, text: text, image: imageDataURL, target: targetCode)
        let clientDataHash = Data(SHA256.hash(data: body))
        let assertion = try await attestor.generateAssertion(keyID, clientDataHash: clientDataHash)

        var request = try makeRequest(path: "/translate")
        request.setValue(keyID, forHTTPHeaderField: "X-Cctrans-Key-Id")
        request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Cctrans-Assertion")
        request.httpBody = body
        return try await sendTranslate(request)
    }

    /// Return a registered keyID, performing one-time attestation if needed.
    private func ensureRegistered(_ attestor: any CctransAttesting) async throws -> String {
        if let existing = attestor.loadKeyID() {
            return existing
        }
        let keyID = try await attestor.generateKey()
        let challenge = try await fetchChallenge(type: "attest", keyID: keyID)
        // attestKey clientDataHash = SHA256(challenge string bytes). The server recomputes
        // nonce = SHA256(authData || that) — must match AppAttestService.verifyAttestation,
        // which hashes the raw challenge string. (Verify end-to-end on a signed device.)
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await attestor.attestKey(keyID, clientDataHash: clientDataHash)
        try await register(keyID: keyID, attestation: attestation, challenge: challenge)
        attestor.saveKeyID(keyID)
        return keyID
    }

    private func fetchChallenge(type: String, keyID: String) async throws -> String {
        var request = try makeRequest(path: "/attest/challenge")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": type, "key_id": keyID])
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenge = object["challenge"] as? String, !challenge.isEmpty else {
            throw CctransManagedError.malformedResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return challenge
    }

    private func register(keyID: String, attestation: Data, challenge: String) async throws {
        var request = try makeRequest(path: "/attest/register")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key_id": keyID,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
        ])
        _ = try await send(request)
    }

    private func encodeBody(
        challenge: String?,
        mode: String,
        text: String?,
        image: String?,
        target: String
    ) throws -> Data {
        // JSONSerialization key order is not guaranteed, but we sign and send the same
        // buffer, and the server hashes the raw received bytes — so ordering is irrelevant.
        var payload: [String: Any] = ["mode": mode, "target": target]
        if let challenge {
            payload["challenge"] = challenge
        }
        if let text {
            payload["text"] = text
        }
        if let image {
            payload["image"] = image
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw CctransManagedError.invalidURL(baseURL + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// `/translate` returns HTTP 200 for BOTH success and quota blocks (ok:true/false);
    /// only auth (401) and engine (502) failures are non-2xx. `send` throws on those.
    private func sendTranslate(_ request: URLRequest) async throws -> CctransManagedOutcome {
        let data: Data
        do {
            data = try await send(request)
        } catch let CctransManagedError.httpStatus(status, body) {
            // 502 = engine/upstream failure (not a quota block); give it a distinct case
            // so callers can treat it as retryable instead of a hard provider error.
            if status == 502 {
                throw CctransManagedError.upstream
            }
            throw CctransManagedError.httpStatus(status, body)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CctransManagedError.malformedResponse(String(data: data, encoding: .utf8) ?? "")
        }

        if object["ok"] as? Bool == true {
            guard let result = object["result"] as? [String: Any] else {
                throw CctransManagedError.malformedResponse(String(data: data, encoding: .utf8) ?? "")
            }
            return .success(
                kind: result["kind"] as? String ?? "text",
                text: result["text"] as? String ?? "",
                imageURL: (result["imageUrl"] as? String)?.nilIfBlank
            )
        }

        // ok:false at HTTP 200 = quota/cap block with display copy (§3). The client
        // shows the copy and never sees the numbers behind it.
        let display = object["display"] as? [String: Any]
        return .blocked(
            action: object["action"] as? String ?? "paywall",
            title: display?["title"] as? String ?? "",
            body: display?["body"] as? String ?? "",
            cta: display?["cta"] as? String ?? ""
        )
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CctransManagedError.malformedResponse(String(data: data, encoding: .utf8) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CctransManagedError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
