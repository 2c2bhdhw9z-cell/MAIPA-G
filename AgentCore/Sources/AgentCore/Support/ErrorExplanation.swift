import Foundation

public struct ErrorExplanation: Sendable, Hashable {
    public var cause: String
    public var nextStep: String
    public var technical: String
    public var isTemporary: Bool

    public init(cause: String, nextStep: String, technical: String, isTemporary: Bool) {
        self.cause = cause
        self.nextStep = nextStep
        self.technical = technical
        self.isTemporary = isTemporary
    }

    public var message: String { "\(cause) \(nextStep)" }
}

public enum ErrorExplainer {
    public static func explain(_ error: Error) -> ErrorExplanation {
        let technical = SensitiveDataRedactor().redact(String(describing: error))
        if error is CancellationError {
            return ErrorExplanation(cause: "The operation was interrupted.", nextStep: "Try again.", technical: technical, isTemporary: true)
        }
        if let error = error as? HTTPError {
            if error.isOffline {
                return ErrorExplanation(cause: "This iPhone is offline.", nextStep: "Reconnect and try again; local work remains on the phone.", technical: technical, isTemporary: true)
            }
            if let status = error.statusCode {
                return ErrorExplanation(cause: "The server returned HTTP \(status).", nextStep: status >= 500 || status == 429 ? "Wait a moment and try again." : "Check the account or request details, then try again.", technical: technical, isTemporary: status >= 500 || status == 429)
            }
        }
        if let error = error as? GitHubAPIError {
            if error.isRateLimited {
                return ErrorExplanation(cause: "GitHub’s request limit was reached.", nextStep: "Wait for the limit to reset, then retry.", technical: technical, isTemporary: true)
            }
            if error.isUnauthorized {
                return ErrorExplanation(cause: "GitHub no longer accepts this sign-in.", nextStep: "Sign in to GitHub again in Settings.", technical: technical, isTemporary: false)
            }
            return ErrorExplanation(cause: "GitHub returned \(error.status): \(error.message)", nextStep: "Fix the named problem and retry.", technical: technical, isTemporary: error.status >= 500)
        }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                return ErrorExplanation(cause: "This iPhone is out of storage space.", nextStep: "Free some storage, then try again.", technical: technical, isTemporary: false)
            case .fileReadNoPermission, .fileWriteNoPermission:
                return ErrorExplanation(cause: "MAIPA-G does not have permission for that file.", nextStep: "Choose an accessible file or update permission, then retry.", technical: technical, isTemporary: false)
            default: break
            }
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return ErrorExplanation(
            cause: description.isEmpty ? "\(String(reflecting: Swift.type(of: error))) failed." : description,
            nextStep: "Try again. Technical details were saved in diagnostics.",
            technical: technical,
            isTemporary: true
        )
    }
}
