import Foundation

/// Actions output is deliberately coarse. It removes registered secret values and never accepts
/// chat text, shell commands, tool output, or transcript objects.
public struct RedactingLogger: Sendable {
    private let secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func redact(_ text: String) -> String {
        secrets.reduce(text) { value, secret in value.replacingOccurrences(of: secret, with: "***") }
    }

    public func progress(_ message: String) {
        print(redact(message.replacingOccurrences(of: "\n", with: " ")))
    }
}
