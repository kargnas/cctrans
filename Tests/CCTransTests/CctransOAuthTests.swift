import CCTransCore
import Foundation
import Testing

struct CctransOAuthTests {
    @Test func authorizationRequestUsesPKCEAndValidatesCallbackState() throws {
        let verifier = String(repeating: "v", count: 64)
        let request = try CctransOAuthAuthorizationRequest(
            state: "state-123",
            codeVerifier: verifier
        )
        let components = try #require(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map { ($0.name, $0.value) })

        #expect(query["client_id"] == CctransOAuthAuthorizationRequest.clientID)
        #expect(query["redirect_uri"] == CctransOAuthAuthorizationRequest.redirectURI)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == "w1TpKUdYE9hUAcNSeeSRFioHDxfUxuHho_JHAfZ_vDM")

        let callback = try #require(URL(string: "cctrans://oauth/callback?code=one-time-code&state=state-123"))
        #expect(try request.authorizationCode(from: callback) == "one-time-code")
    }

    @Test func callbackRejectsWrongStateAndCancellation() throws {
        let request = try CctransOAuthAuthorizationRequest(
            state: "expected",
            codeVerifier: String(repeating: "v", count: 64)
        )
        let wrongState = try #require(URL(string: "cctrans://oauth/callback?code=code&state=wrong"))
        let cancelled = try #require(URL(string: "cctrans://oauth/callback?error=access_denied&state=expected"))

        #expect(throws: CctransOAuthError.stateMismatch) {
            try request.authorizationCode(from: wrongState)
        }
        #expect(throws: CctransOAuthError.cancelled) {
            try request.authorizationCode(from: cancelled)
        }
    }

    @Test func callbackRejectsDuplicateParametersAndValidatesStateBeforeProviderError() throws {
        let request = try CctransOAuthAuthorizationRequest(
            state: "expected",
            codeVerifier: String(repeating: "v", count: 64)
        )
        let duplicateCode = try #require(URL(string: "cctrans://oauth/callback?code=one&code=two&state=expected"))
        let forgedCancellation = try #require(URL(string: "cctrans://oauth/callback?error=access_denied&state=wrong"))

        #expect(throws: CctransOAuthError.invalidCallback) {
            try request.authorizationCode(from: duplicateCode)
        }
        #expect(throws: CctransOAuthError.stateMismatch) {
            try request.authorizationCode(from: forgedCancellation)
        }
    }
}
