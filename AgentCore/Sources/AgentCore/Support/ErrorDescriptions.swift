import Foundation

// iOS shows an error's `localizedDescription`. A Swift error that doesn't say otherwise becomes
// "The operation couldn't be completed (AgentCore.X error 1.)", which hides the real reason. These
// give iOS the message each MAIPA-G error already has.

extension GitHubAPIError: LocalizedError { public var errorDescription: String? { description } }
extension GitLFSError: LocalizedError { public var errorDescription: String? { description } }
extension GitHubChangeFailure: LocalizedError { public var errorDescription: String? { description } }
extension MCPAuthorizationError: LocalizedError { public var errorDescription: String? { description } }
extension ComputerControl.Failure: LocalizedError { public var errorDescription: String? { description } }
extension OpenRouterAPIError: LocalizedError { public var errorDescription: String? { description } }
extension WebPreviewError: LocalizedError { public var errorDescription: String? { description } }
extension ChangeWorkspaceError: LocalizedError { public var errorDescription: String? { description } }
extension SearchError: LocalizedError { public var errorDescription: String? { description } }
extension SnapshotError: LocalizedError { public var errorDescription: String? { description } }
extension SpecFailure: LocalizedError { public var errorDescription: String? { description } }
extension WebPageError: LocalizedError { public var errorDescription: String? { description } }
extension ToolInputError: LocalizedError { public var errorDescription: String? { description } }
extension RepoHookProblem: LocalizedError { public var errorDescription: String? { description } }

extension HTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let message, _): message
        case .status(let code, let body, _): "The server answered HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(300))")"
        case .undecodable: description
        }
    }
}

extension DataRepoSync.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSetUp: "Saving to GitHub isn't set up yet. Connect GitHub in Settings."
        case .repoNotVisible: "MAIPA-G-data exists, but MAIPA-G's GitHub app isn't allowed into it. Add MAIPA-G-data to the app's repository access on GitHub."
        }
    }
}

public extension ErrorExplainer {
    /// iOS's placeholder for an error with no message of its own.
    static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("The operation couldn’t be completed") || text.hasPrefix("The operation couldn't be completed") || text.hasPrefix("The operation could not be completed")
    }
}
