import Foundation

/// Runs one Autonomous job on the chat computer with the same CloudRunner GitHub Actions used:
/// the job's record and checkpoints stay in the private data repo. There is no 6-hour limit here,
/// so the job never hands over to a fresh runner.
public struct VMJobRunner: Sendable {
    public let folder: URL
    public let runnerDirectory: URL
    private let transport: any HTTPTransport

    public init(folder: URL, runnerDirectory: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.folder = folder; self.runnerDirectory = runnerDirectory; self.transport = transport
    }

    public func run() async throws {
        let request = try VMCoding.unpack(VMJobRequest.self, from: Data(contentsOf: folder.appendingPathComponent("request.json.gz")))
        let secrets = try VMRunFiles.takeSecrets(in: folder)
        let logger = RedactingLogger(secrets: secrets.allValues)
        guard let token = secrets.githubToken, !token.isEmpty else { throw CloudRunnerError.missingWorkflowIdentity }
        let workspace = folder.appendingPathComponent("work", isDirectory: true)
        try await checkout(request: request, token: token, into: workspace, logger: logger)
        var connectorSecrets = secrets.connectorSecrets
        if !secrets.providers.isEmpty, let data = try? JSONCoding.encoder().encode(secrets.providers) {
            connectorSecrets["__ai_providers_json"] = String(decoding: data, as: UTF8.self)
        }
        let configuration = CloudRunnerConfiguration(
            jobID: request.jobID,
            targetRepository: request.targetRepository,
            workspace: workspace,
            trustedRunnerDirectory: runnerDirectory,
            ipaChecker: try? Data(contentsOf: CloudToolAssembly.ipaCheckerURL(in: runnerDirectory)),
            targetToken: token,
            dataToken: secrets.dataToken ?? token,
            dataRepository: request.dataRepository,
            dataBranch: request.dataBranch,
            connectorSecrets: connectorSecrets,
            openRouterKey: secrets.openRouterKey ?? "__external_only__",
            handoverAfter: 60 * 60 * 24 * 30,
            tokenRefreshFile: folder.appendingPathComponent("token-refresh.json.gz")
        )
        logger.progress("MAIPA-G started job \(request.jobID.uuidString) on this computer.")
        try await CloudRunner(configuration: configuration, transport: transport).run()
    }

    /// Clones the job's repo at its branch. The token reaches git through its environment only.
    func checkout(request: VMJobRequest, token: String, into workspace: URL, logger: RedactingLogger) async throws {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        var environment = ComputerControl.localEnvironment(home: home, from: ProcessInfo.processInfo.environment)
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
        environment["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic " + Data("x-access-token:\(token)".utf8).base64EncodedString()
        try? FileManager.default.removeItem(at: workspace)
        let url = request.targetRepository.webURL.absoluteString + ".git"
        let result = try await BoundedProcess.run(
            executable: "/usr/bin/git", arguments: ["clone", "--quiet", "--branch", request.targetRef, url, workspace.path],
            directory: folder, environment: environment, replacingEnvironment: true, timeout: 900
        )
        guard result.exitCode == 0 else {
            logger.progress("Cloning \(request.targetRepository.fullName) failed: \(logger.redact(result.stderr))")
            throw CloudRunnerError.commandFailed
        }
    }
}
