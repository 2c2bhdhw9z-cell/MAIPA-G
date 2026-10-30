import Foundation

/// Actions output is deliberately coarse. It removes registered secret values and never accepts
/// chat text, shell commands, tool output, or transcript objects.
public struct RedactingLogger: Sendable {
    private let redactor: SensitiveDataRedactor

    public init(secrets: [String] = []) {
        redactor = SensitiveDataRedactor(secrets: secrets)
    }

    public func redact(_ text: String) -> String {
        redactor.redact(text).replacingOccurrences(of: SensitiveDataRedactor.marker, with: "***")
    }

    public func progress(_ message: String) {
        print(redact(message.replacingOccurrences(of: "\n", with: " ")))
    }
}
