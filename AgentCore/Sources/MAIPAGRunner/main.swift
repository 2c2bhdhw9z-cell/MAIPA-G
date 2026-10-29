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
        guard
            let idText = environment["MAIPAG_JOB_ID"], let id = UUID(uuidString: idText),
            let repoText = environment["GITHUB_REPOSITORY"], let repo = RepoRef(fullName: repoText),
            let workspace = environment["GITHUB_WORKSPACE"],
            let githubToken = environment["MAIPAG_GITHUB_TOKEN"], !githubToken.isEmpty,
            let openRouterKey = environment["OPENROUTER_API_KEY"], !openRouterKey.isEmpty
        else {
            FileHandle.standardError.write(Data("MAIPAGRunner: required Actions environment is missing. Use --help for usage.\n".utf8))
            exit(2)
        }
        let configuration = CloudRunnerConfiguration(
            jobID: id,
            targetRepository: repo,
            workspace: URL(fileURLWithPath: workspace, isDirectory: true),
            githubToken: githubToken,
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
