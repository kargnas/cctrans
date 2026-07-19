import AppKit
import AuthenticationServices
import Foundation

enum CctransAppleSignInError: LocalizedError {
    case cancelled
    case invalidCredential
    case missingIdentityToken
    case requestInProgress

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign in with Apple was cancelled."
        case .invalidCredential:
            "Apple returned an unexpected credential."
        case .missingIdentityToken:
            "Apple did not return an identity token."
        case .requestInProgress:
            "Another Apple sign-in request is already running."
        }
    }
}

@MainActor
final class CctransAppleSignIn: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    struct AuthorizationPayload {
        let identityToken: Data
        let name: PersonNameComponents?
    }

    struct Credential {
        let identityToken: String
        let nonce: String
        let name: String?
    }

    typealias AuthorizationHandler = @MainActor (String) async throws -> AuthorizationPayload

    private let authorizationHandler: AuthorizationHandler?
    private var continuation: CheckedContinuation<AuthorizationPayload, any Error>?
    private var controller: ASAuthorizationController?

    init(authorizationHandler: AuthorizationHandler? = nil) {
        self.authorizationHandler = authorizationHandler
    }

    func authorize() async throws -> Credential {
        let nonce = UUID().uuidString.lowercased()
        let payload: AuthorizationPayload
        if let authorizationHandler {
            payload = try await authorizationHandler(nonce)
        } else {
            payload = try await authorizeNatively(nonce: nonce)
        }
        guard let identityToken = String(data: payload.identityToken, encoding: .utf8),
              !identityToken.isEmpty else {
            throw CctransAppleSignInError.missingIdentityToken
        }
        let name = payload.name.map { PersonNameComponentsFormatter().string(from: $0) }
        return Credential(identityToken: identityToken, nonce: nonce, name: name)
    }

    private func authorizeNatively(nonce: String) async throws -> AuthorizationPayload {
        guard continuation == nil else {
            throw CctransAppleSignInError.requestInProgress
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken else {
            finish(.failure(CctransAppleSignInError.invalidCredential))
            return
        }
        finish(.success(AuthorizationPayload(identityToken: identityToken, name: credential.fullName)))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.failure(CctransAppleSignInError.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<AuthorizationPayload, any Error>) {
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}
