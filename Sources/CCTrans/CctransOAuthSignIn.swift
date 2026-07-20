import AppKit
import AuthenticationServices
import CCTransCore
import Foundation

@MainActor
final class CctransOAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Credential {
        let code: String
        let codeVerifier: String
        let redirectURI: String
    }

    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: ASWebAuthenticationSession?

    func authorize() async throws -> Credential {
        guard session == nil else {
            throw CctransOAuthError.requestInProgress
        }
        let request = try CctransOAuthAuthorizationRequest.make()
        let callbackURL = try await callbackURL(for: request.authorizationURL)
        return Credential(
            code: try request.authorizationCode(from: callbackURL),
            codeVerifier: request.codeVerifier,
            redirectURI: CctransOAuthAuthorizationRequest.redirectURI
        )
    }

    func cancel() {
        let currentSession = session
        currentSession?.cancel()
        finish(.failure(CctransOAuthError.cancelled))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
    }

    private func callbackURL(for authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "cctrans"
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    if let callbackURL {
                        self?.finish(.success(callbackURL))
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        self?.finish(.failure(CctransOAuthError.cancelled))
                    } else {
                        self?.finish(.failure(error ?? CctransOAuthError.invalidCallback))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                finish(.failure(CctransOAuthError.couldNotStart))
            }
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        let continuation = continuation
        self.continuation = nil
        session = nil
        continuation?.resume(with: result)
    }
}
