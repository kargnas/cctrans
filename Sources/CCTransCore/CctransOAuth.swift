import CryptoKit
import Foundation

public enum CctransOAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidAuthorizationURL
    case requestInProgress
    case couldNotStart
    case cancelled
    case invalidCallback
    case stateMismatch
    case missingCode
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            "CCTrans Cloud returned an invalid sign-in URL."
        case .requestInProgress:
            "Another browser sign-in is already running."
        case .couldNotStart:
            "Could not open the browser sign-in session."
        case .cancelled:
            "Browser sign-in was cancelled."
        case .invalidCallback:
            "CCTrans Cloud returned an invalid sign-in callback."
        case .stateMismatch:
            "The browser sign-in state did not match. Please try again."
        case .missingCode:
            "CCTrans Cloud did not return an authorization code."
        case let .provider(message):
            message
        }
    }
}

public struct CctransOAuthAuthorizationRequest: Equatable, Sendable {
    public static let defaultAuthorizationURL = "https://kargn.as/cctrans/oauth/authorize"
    public static let clientID = "cctrans-macos"
    public static let redirectURI = "cctrans://oauth/callback"

    public let authorizationURL: URL
    public let state: String
    public let codeVerifier: String

    public static func make(
        authorizationURL: String = defaultAuthorizationURL
    ) throws -> Self {
        try Self(
            authorizationURL: authorizationURL,
            state: randomToken(),
            codeVerifier: randomToken()
        )
    }

    package init(
        authorizationURL: String = defaultAuthorizationURL,
        state: String,
        codeVerifier: String
    ) throws {
        guard var components = URLComponents(string: authorizationURL) else {
            throw CctransOAuthError.invalidAuthorizationURL
        }
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw CctransOAuthError.invalidAuthorizationURL
        }
        self.authorizationURL = url
        self.state = state
        self.codeVerifier = codeVerifier
    }

    public func authorizationCode(from callbackURL: URL) throws -> String {
        guard callbackURL.scheme == "cctrans",
              callbackURL.host == "oauth",
              callbackURL.path == "/callback",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw CctransOAuthError.invalidCallback
        }
        let values = Dictionary(grouping: components.queryItems ?? [], by: \.name)
        guard values.values.allSatisfy({ $0.count == 1 }) else {
            throw CctransOAuthError.invalidCallback
        }
        let value: (String) -> String? = { values[$0]?.first?.value }
        guard value("state") == state else {
            throw CctransOAuthError.stateMismatch
        }
        if value("error") == "access_denied" {
            throw CctransOAuthError.cancelled
        }
        if let error = value("error") {
            throw CctransOAuthError.provider(error)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw CctransOAuthError.missingCode
        }
        return code
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<48).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
