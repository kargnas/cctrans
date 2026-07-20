import AppKit
import AuthenticationServices
import CCTransCore
import Foundation
import Synchronization

@MainActor
final class CctransOAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Credential {
        let code: String
        let codeVerifier: String
        let redirectURI: String
    }

    // The ASWebAuthenticationSession completion fires on a background XPC thread.
    // The @Sendable completion closure (see below) must NOT be MainActor-isolated,
    // or the Swift 6 runtime asserts the wrong executor and crashes. It resumes the
    // continuation through this box: nonisolated + Sendable (Mutex-guarded) so the
    // XPC-thread completion can touch it safely, while cancel() on the main actor
    // serializes through the same Mutex — the continuation resumes exactly once.
    // ASWebAuthenticationSession itself is non-Sendable and stays on the actor.
    private final class StateBox: Sendable {
        let continuation = Mutex<CheckedContinuation<URL, any Error>?>(nil)

        func finish(_ result: Result<URL, any Error>) {
            let continuation = continuation.withLock { current -> CheckedContinuation<URL, any Error>? in
                defer { current = nil }
                return current
            }
            // Resuming a continuation is thread-safe by design.
            continuation?.resume(with: result)
        }
    }

    private let state = StateBox()
    private var session: ASWebAuthenticationSession?

    func authorize() async throws -> Credential {
        guard session == nil else {
            throw CctransOAuthError.requestInProgress
        }
        let request = try CctransOAuthAuthorizationRequest.make()
        let callbackURL = try await callbackURL(for: request.authorizationURL)
        session = nil
        return Credential(
            code: try request.authorizationCode(from: callbackURL),
            codeVerifier: request.codeVerifier,
            redirectURI: CctransOAuthAuthorizationRequest.redirectURI
        )
    }

    func cancel() {
        session?.cancel()
        session = nil
        state.finish(.failure(CctransOAuthError.cancelled))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
    }

    private func callbackURL(for authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            state.continuation.withLock { $0 = continuation }
            // @Sendable strips the MainActor isolation this closure would
            // otherwise inherit from the enclosing @MainActor method. Without it,
            // ASWebAuthenticationSession invoking the handler on its background XPC
            // thread trips the Swift 6 executor precondition
            // (swift_task_checkIsolatedSwift → dispatch_assert_queue_fail →
            // EXC_BREAKPOINT). It captures only the Sendable StateBox, so the
            // Mutex inside handles the cross-thread resume.
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "cctrans"
            ) { @Sendable [state] callbackURL, error in
                let result: Result<URL, any Error>
                if let callbackURL {
                    result = .success(callbackURL)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    result = .failure(CctransOAuthError.cancelled)
                } else {
                    result = .failure(error ?? CctransOAuthError.invalidCallback)
                }
                state.finish(result)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                state.finish(.failure(CctransOAuthError.couldNotStart))
            }
        }
    }
}
