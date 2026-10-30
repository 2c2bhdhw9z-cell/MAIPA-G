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
        // Reads and deletes the credential files and clears their variables before anything runs.
        let secrets = RunnerSecrets.take(environment: environment)
        let targetSecret = secrets["MAIPAG_TARGET_TOKEN_FILE"]
        let dataSecret = secrets["MAIPAG_DATA_TOKEN_FILE"]
        let openRouterSecret = secrets["OPENROUTER_API_KEY_FILE"]
        let mcpSecretText = secrets["MAIPAG_MCP_SECRETS_FILE"] ?? ""
        guard
            let idText = environment["MAIPAG_JOB_ID"], let id = UUID(uuidString: idText),
            let repoText = environment["GITHUB_REPOSITORY"], let repo = RepoRef(fullName: repoText),
            let workspace = environment["GITHUB_WORKSPACE"],
            let runnerRoot = environment["MAIPAG_RUNNER_ROOT"],
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
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL
        let runnerURL = URL(fileURLWithPath: runnerRoot, isDirectory: true).standardizedFileURL
        guard !runnerURL.path.hasPrefix(workspaceURL.path + "/"),
              let ipaChecker = try? Data(contentsOf: CloudToolAssembly.ipaCheckerURL(in: runnerURL)),
              !ipaChecker.isEmpty else {
            FileHandle.standardError.write(Data("MAIPAGRunner: trusted runner files must be outside the target workspace.\n".utf8))
            exit(2)
        }
        // RunnerSecrets.take deleted the files and cleared their variables above, before any
        // model-directed shell or third-party MCP child starts.
        let configuration = CloudRunnerConfiguration(
            jobID: id,
            targetRepository: repo,
            workspace: workspaceURL,
            trustedRunnerDirectory: runnerURL,
            ipaChecker: ipaChecker,
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
