import AuthenticationServices
import UIKit

/// Opens a sign-in page in iOS's secure web sheet and waits for it to send the user back to
/// MAIPA-G's own address (maipag://…). The sheet shares Safari's sign-ins, so someone already
/// signed in to GitHub or OpenRouter in Safari doesn't have to sign in again. MAIPA-G never sees
/// passwords: only the code the service sends back.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebSignIn()

    enum Failure: Error, Equatable {
        /// The user closed the sheet.
        case cancelled
        case couldNotOpen
        case noAnswer
    }

    private var current: ASWebAuthenticationSession?

    /// Shows `url` and returns the maipag:// address the page sent the user to.
    func open(_ url: URL, scheme: String = "maipag") async throws -> URL {
        current?.cancel()
        defer { current = nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let finish: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: error ?? Failure.noAnswer)
                }
            }
            let session: ASWebAuthenticationSession
            if #available(iOS 17.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: finish)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: finish)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            current = session
            if !session.start() {
                current = nil
                continuation.resume(throwing: Failure.couldNotOpen)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            if let key = windows.first(where: \.isKeyWindow) ?? windows.first { return key }
            return ASPresentationAnchor(windowScene: scenes.first!)
        }
    }

    /// The query values of a callback address, such as code and state.
    static func values(in url: URL) -> [String: String] {
        var values: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        return values
    }
}
