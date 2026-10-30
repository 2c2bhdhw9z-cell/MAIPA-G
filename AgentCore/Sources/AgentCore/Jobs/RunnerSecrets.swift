import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How MAIPAGRunner takes its credentials on GitHub Actions: agent.yml writes each one to a
/// private file and passes only the file's path. The runner reads every file, deletes it, and
/// removes the path variables (and any GitHub token) from its own environment before any model-
/// or repo-chosen command starts, so those commands can't find or read a credential.
public enum RunnerSecrets {
    public static let fileVariables = ["MAIPAG_TARGET_TOKEN_FILE", "MAIPAG_DATA_TOKEN_FILE", "OPENROUTER_API_KEY_FILE", "MAIPAG_MCP_SECRETS_FILE"]
    public static let tokenVariables = ["GH_TOKEN", "GITHUB_TOKEN", "MAIPAG_TARGET_TOKEN", "MAIPAG_DATA_TOKEN", "OPENROUTER_API_KEY", "MAIPAG_MCP_SECRETS"]

    /// Reads and deletes every credential file, then clears the variables. Returns the values by
    /// variable name; an empty or missing file has no entry.
    public static func take(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var values: [String: String] = [:]
        for variable in fileVariables {
            guard let path = environment[variable], !path.isEmpty else { continue }
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { continue }
            values[variable] = String(decoding: data, as: UTF8.self)
        }
        for variable in fileVariables + tokenVariables { unsetenv(variable) }
        return values
    }
}
