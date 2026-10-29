import AgentCore
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
enum MAIPAGRunnerMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            MAIPAGRunner

            Runs one private, restartable MAIPA-G Autonomous job. GitHub Actions supplies the
            opaque job id and credentials through its masked environment.

            Usage: MAIPAGRunner [--help]
            """)
            return
        }
        let environment = ProcessInfo.processInfo.environment
        func takeSecret(_ variable: String) -> String? {
            guard let path = environment[variable], !path.isEmpty else { return nil }
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let targetSecret = takeSecret("MAIPAG_TARGET_TOKEN_FILE")
        let dataSecret = takeSecret("MAIPAG_DATA_TOKEN_FILE")
        let openRouterSecret = takeSecret("OPENROUTER_API_KEY_FILE")
        let mcpSecretText = takeSecret("MAIPAG_MCP_SECRETS_FILE") ?? ""
        guard
            let idText = environment["MAIPAG_JOB_ID"], let id = UUID(uuidString: idText),
            let repoText = environment["GITHUB_REPOSITORY"], let repo = RepoRef(fullName: repoText),
            let workspace = environment["GITHUB_WORKSPACE"],
            let targetToken = targetSecret, !targetToken.isEmpty,
            let dataToken = dataSecret, !dataToken.isEmpty,
            let dataOwner = environment["MAIPAG_DATA_OWNER"],
            let dataRepoName = environment["MAIPAG_DATA_REPO"],
            let dataBranch = environment["MAIPAG_DATA_BRANCH"], !dataBranch.isEmpty,
            let openRouterKey = openRouterSecret, !openRouterKey.isEmpty
        else {
            FileHandle.standardError.write(Data("MAIPAGRunner: required Actions environment is missing. Use --help for usage.\n".utf8))
            exit(2)
        }
        let connectorSecrets: [String: String] = (try? JSONDecoder().decode([String: String].self, from: Data(mcpSecretText.utf8))) ?? [:]
        // Secret files are deleted above and only nonsecret file-path variables remain in the
        // inherited environment before any model-directed shell or third-party MCP child starts.
        for key in ["MAIPAG_TARGET_TOKEN_FILE", "MAIPAG_DATA_TOKEN_FILE", "OPENROUTER_API_KEY_FILE", "MAIPAG_MCP_SECRETS_FILE", "GH_TOKEN", "GITHUB_TOKEN"] {
            unsetenv(key)
        }
        let configuration = CloudRunnerConfiguration(
            jobID: id,
            targetRepository: repo,
            workspace: URL(fileURLWithPath: workspace, isDirectory: true),
            targetToken: targetToken,
            dataToken: dataToken,
            dataRepository: RepoRef(owner: dataOwner, name: dataRepoName),
            dataBranch: dataBranch,
            connectorSecrets: connectorSecrets,
            openRouterKey: openRouterKey,
            runID: environment["GITHUB_RUN_ID"].flatMap(Int.init)
        )
        do {
            try await CloudRunner(configuration: configuration).run()
        } catch {
            // Error details can contain provider bodies or tool output. The private checkpoint has
            // the useful state; Actions receives only this safe failure line.
            FileHandle.standardError.write(Data("MAIPAGRunner: the job stopped safely; open MAIPA-G for details.\n".utf8))
            exit(1)
        }
    }
}
