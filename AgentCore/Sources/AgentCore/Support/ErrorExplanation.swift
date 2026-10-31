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

/// Where explained errors are also written, so the redacted diagnostics log sees every failure the
/// person is shown, not only the ones a call site remembered to report.
public final class ErrorRecorder: @unchecked Sendable {
    public typealias Record = @Sendable (_ error: Error, _ area: String, _ operation: String) -> Void
    private let lock = NSLock()
    private var record: Record?

    public func set(_ record: Record?) {
        lock.lock(); self.record = record; lock.unlock()
    }

    func callAsFunction(_ error: Error, area: String, operation: String) {
        lock.lock(); let record = self.record; lock.unlock()
        record?(error, area, operation)
    }
}

public enum ErrorExplainer {
    public static let recorder = ErrorRecorder()

    /// Explains `error` for the person and records it (redacted) in the diagnostics log, named by
    /// the file and function that hit it.
    public static func explain(_ error: Error, file: String = #fileID, function: String = #function) -> ErrorExplanation {
        let explanation = describe(error)
        if !(error is CancellationError) {
            let area = file.split(separator: "/").last.map { String($0.split(separator: ".").first ?? $0) } ?? file
            recorder(error, area: area, operation: function)
        }
        return explanation
    }

    /// The explanation alone, without recording it (for the diagnostics log itself).
    public static func describe(_ error: Error) -> ErrorExplanation {
        let technical = SensitiveDataRedactor().redact(String(describing: error))
        if error is CancellationError {
            return ErrorExplanation(cause: "The operation was interrupted.", nextStep: "Try again.", technical: technical, isTemporary: true)
        }
        if let error = error as? HTTPError {
            if error.isOffline {
                return ErrorExplanation(cause: "This iPhone is offline.", nextStep: "Reconnect and try again; local work remains on the phone.", technical: technical, isTemporary: true)
            }
            if case .transport(let message, _) = error {
                return ErrorExplanation(cause: "The connection failed: \(message)", nextStep: "MAIPA-G tries again by itself; check the connection if it keeps happening.", technical: technical, isTemporary: true)
            }
            if let status = error.statusCode {
                return ErrorExplanation(cause: "The server returned HTTP \(status).", nextStep: status >= 500 || status == 429 ? "Wait a moment and try again." : "Check the account or request details, then try again.", technical: technical, isTemporary: status >= 500 || status == 429)
            }
        }
        if let api = error as? OpenRouterAPIError {
            switch api.kind {
            case .invalidKey:
                return ErrorExplanation(cause: "\(api.providerName) rejected the API key.", nextStep: "Update the key for \(api.providerName) in Settings.", technical: technical, isTemporary: false)
            case .outOfCredits:
                return ErrorExplanation(cause: "\(api.providerName) reported no remaining credits.", nextStep: "Add credit in \(api.providerName) or switch AI providers.", technical: technical, isTemporary: false)
            case .rateLimited:
                return ErrorExplanation(cause: "\(api.providerName) is rate-limiting requests right now.", nextStep: "Wait up to 60 seconds or choose another model.", technical: technical, isTemporary: true)
            case .appRestricted:
                return ErrorExplanation(cause: "That model is restricted by its publisher on \(api.providerName) and was hidden from the AI picker.", nextStep: "Pick another AI model.", technical: technical, isTemporary: false)
            default:
                return ErrorExplanation(cause: "\(api.providerName) returned HTTP \(api.httpStatus): \(api.message)", nextStep: "Try again or choose another AI model.", technical: technical, isTemporary: api.httpStatus >= 500)
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
        var description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never show iOS's "The operation couldn't be completed (… error 1)" placeholder: say
        // what the error itself says instead.
        if description.isEmpty || isPlaceholder(description) {
            description = SensitiveDataRedactor().redact(String(describing: error))
        }
        return ErrorExplanation(
            cause: description.isEmpty ? "\(String(reflecting: Swift.type(of: error))) failed." : description,
            nextStep: "Try again. Technical details were saved in diagnostics.",
            technical: technical,
            isTemporary: true
        )
    }
}
