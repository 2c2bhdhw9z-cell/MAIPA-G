import Foundation
import ZIPFoundation

/// Kiro's `gh run download` and `gh release download`: a GitHub Actions artifact or a release file
/// onto the chat computer, with MAIPA-G's GitHub sign-in. git and curl there have no GitHub
/// sign-in (the phone's key never goes there), so the Korg reply couldn't fetch the loader its
/// CI had just built and had to reuse an older one (14 November 2026).
public struct DownloadFromGitHubTool: AgentTool {
    public static let toolName = "download_from_github"
    public let name = DownloadFromGitHubTool.toolName
    let github: GitHubClient
    let home: URL

    public init(github: GitHubClient, home: URL) {
        self.github = github
        self.home = home
    }

    /// Most files listed from an unpacked artifact.
    static let listedFiles = 60

    public var spec: ToolSpec {
        ToolSpec(name: name, description: """
        Download a GitHub Actions artifact or a release file onto this computer, signed in as MAIPA-G (git and curl \
        here have no GitHub sign-in, so they can't). Give a run's artifact (https://api.github.com/repos/o/r/actions/\
        artifacts/<id>/zip, or its github.com run page link), a release download link (github.com/o/r/releases/download/\
        <tag>/<file>) or a release asset API address. Artifacts are zips and are unpacked unless unzip is false. Files go \
        under ~/downloads unless you give a folder. Find artifact ids with mcp_github_api_request \
        (GET /repos/o/r/actions/runs/<run id>/artifacts). To give the person a file, use send_file instead.
        """, parameters: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "The artifact, release download or release asset address."],
                "folder": ["type": "string", "description": "Folder under the home folder to put it in, like \"downloads/loader\" or \"repos/o/r/build\". Default downloads."],
                "unzip": ["type": "boolean", "description": "Unpack a zip into the folder. Default true."],
            ],
            "required": ["url"],
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Downloading from GitHub…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let raw = try arguments.requiredString("url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(), host == "github.com" || host == "api.github.com" else {
            throw ToolInputError("Give a github.com or api.github.com address. For other downloads, use curl with run_command.")
        }
        var folderPath = arguments.optionalString("folder")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "downloads"
        for prefix in ["~/", "$HOME/", home.path + "/"] where folderPath.hasPrefix(prefix) { folderPath.removeFirst(prefix.count) }
        if folderPath.isEmpty { folderPath = "downloads" }
        guard ComputerControl.isSafeRelativePath(folderPath) else { throw ToolInputError("Give a folder inside the home folder, like downloads/loader.") }
        let folder = home.appendingPathComponent(folderPath, isDirectory: true)
        let apiURL = try await SendFileTool.apiDownloadURL(for: url, github: github)
        let scratch = home.appendingPathComponent(".maipa-g/downloads/\(UUID().uuidString.lowercased())", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        progress("Downloading from GitHub…")
        try await github.downloadAuthenticatedArtifact(at: apiURL, to: scratch)
        let size = ((try? FileManager.default.attributesOfItem(atPath: scratch.path)[.size]) as? Int) ?? 0
        guard size > 0 else { throw ToolInputError("GitHub sent an empty file for \(raw).") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let unzip = arguments.optionalBool("unzip") ?? true
        if unzip, SendFileTool.isZip(scratch) {
            let files = try Self.unpack(scratch, into: folder)
            let listed = files.prefix(Self.listedFiles).map { "~/\(folderPath)/\($0.path) (\(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file)))" }
            let more = files.count > Self.listedFiles ? "\n… and \(files.count - Self.listedFiles) more" : ""
            return ToolOutput(
                forModel: "Downloaded \(sizeText) from GitHub and unpacked \(files.count) file\(files.count == 1 ? "" : "s") into ~/\(folderPath):\n" + listed.joined(separator: "\n") + more,
                summary: "Downloaded \(files.count) file\(files.count == 1 ? "" : "s") from GitHub"
            )
        }
        let name = Self.fileName(for: url, apiURL: apiURL)
        let target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: scratch, to: target)
        return ToolOutput(forModel: "Downloaded \(sizeText) from GitHub to ~/\(folderPath)/\(name).", summary: "Downloaded \(name) from GitHub")
    }

    /// The name to save a download under: a release file keeps its own name.
    static func fileName(for url: URL, apiURL: String) -> String {
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 6, parts[2] == "releases", parts[3] == "download", let last = parts.last, SnapshotStore.isSafeRelativePath(last) { return last }
        if let id = apiURL.split(separator: "/").last(where: { Int($0) != nil }) {
            return apiURL.contains("/actions/artifacts/") ? "artifact-\(id).zip" : "asset-\(id)"
        }
        return "download"
    }

    /// Unpacks the zip's files into `folder`. An entry that would land outside it (`../`) or is a
    /// link is skipped. Returns each file's path inside the folder and its size.
    static func unpack(_ zip: URL, into folder: URL) throws -> [(path: String, bytes: Int)] {
        guard let archive = Archive(url: zip, accessMode: .read) else { throw ToolInputError("The download isn't a zip that can be opened.") }
        let root = folder.standardizedFileURL.path
        var files: [(path: String, bytes: Int)] = []
        for entry in archive where entry.type == .file && !entry.path.hasPrefix("__MACOSX/") {
            let target = folder.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            _ = try archive.extract(entry, to: target)
            files.append((String(target.path.dropFirst(root.count + 1)), Int(entry.uncompressedSize)))
        }
        return files.sorted { $0.path < $1.path }
    }
}
