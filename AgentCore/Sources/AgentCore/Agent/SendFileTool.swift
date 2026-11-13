import Foundation
import ZIPFoundation

/// Hands the person a file right in the chat: a built .ipa or .deb, a zip, a document. It shows as
/// a card they tap to save it or open it in another app (a sideloading app, Files). Download links
/// to GitHub artifacts need a GitHub sign-in the person doesn't have in Safari, so the AI used to
/// paste links that couldn't be opened (11 November 2026).
public struct SendFileTool: AgentTool {
    public let name = "send_file"
    let github: GitHubClient?
    let transport: any HTTPTransport
    let computer: ComputerControl?
    let store: AttachmentStore
    let workDirectory: URL

    public init(github: GitHubClient?, transport: any HTTPTransport, computer: ComputerControl?, store: AttachmentStore, workDirectory: URL = FileManager.default.temporaryDirectory) {
        self.github = github
        self.transport = transport
        self.computer = computer
        self.store = store
        self.workDirectory = workDirectory
    }

    public static let maximumBytes = 250 * 1024 * 1024

    public var spec: ToolSpec {
        var properties: [String: JSONValue] = [
            "url": ["type": "string", "description": "An https address: a GitHub Actions artifact (api.github.com/…/artifacts/<id>/zip), a release asset, or any download."],
            "pick": ["type": "string", "description": "Optional: when the download is a zip, the file inside it to send (such as Vellum.deb). Without it, a zip holding one file (or one .ipa) sends that file."],
            "name": ["type": "string", "description": "Optional file name to show."],
        ]
        if computer != nil {
            properties["computer_path"] = ["type": "string", "description": "A file on the chat computer, inside the home folder (such as repos/me/app/build/App.ipa)."]
        }
        return ToolSpec(name: name, description: "Give the person a file in the chat as a card they tap to save it or open it in another app (a built .ipa, .deb or .dylib, a zip, a PDF). Use this whenever you'd otherwise paste a download link: GitHub artifact links need a sign-in the person doesn't have. Give either url or computer_path.", parameters: [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Getting the file…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let folder = workDirectory.appendingPathComponent("maipa-g-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var file: URL
        var shownName: String
        if let path = arguments.optionalString("computer_path")?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            guard let computer else { throw ToolInputError("This chat has no computer to take the file from.") }
            var relative = path
            for prefix in ["~/", "$HOME/", "/home/sprite/"] where relative.hasPrefix(prefix) { relative.removeFirst(prefix.count) }
            guard ComputerControl.isSafeRelativePath(relative) else { throw ToolInputError("Give a path inside the computer's home folder.") }
            progress("Bringing the file from the computer…")
            shownName = (relative as NSString).lastPathComponent
            file = folder.appendingPathComponent(shownName)
            // As big as a chat file can be, so a rebuilt app (often 150 MB or more) comes back too.
            try await computer.readFile(homePath: relative, maxBytes: AttachmentStore.maximumAttachmentBytes).write(to: file)
        } else if let raw = arguments.optionalString("url"), let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() {
            progress("Downloading the file…")
            shownName = url.lastPathComponent.isEmpty || url.lastPathComponent == "zip" ? "download.zip" : url.lastPathComponent
            file = folder.appendingPathComponent("download")
            if host == "api.github.com" || host == "github.com" {
                guard let github else { throw ToolInputError("GitHub isn't connected, so its files can't be downloaded.") }
                let apiURL = try await Self.apiDownloadURL(for: url, github: github)
                if apiURL.contains("/releases/assets/") { shownName = url.lastPathComponent }
                try await github.downloadAuthenticatedArtifact(at: apiURL, to: file)
            } else {
                let response = try await transport.download(HTTPRequest(url: url, idleTimeout: 180), to: file, progress: nil)
                guard response.isSuccess else { throw ToolInputError("The download answered HTTP \(response.status).") }
            }
            if url.path.contains("/artifacts/") { shownName = "artifact.zip" }
        } else {
            throw ToolInputError("Give an https url or a computer_path.")
        }
        // A zip (every GitHub Actions artifact is one) gives the file inside it.
        if Self.isZip(file), let inner = try Self.choose(in: file, pick: arguments.optionalString("pick"), into: folder.appendingPathComponent("unzipped", isDirectory: true)) {
            file = inner
            shownName = inner.lastPathComponent
        }
        if let wanted = arguments.optionalString("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty, !wanted.contains("/") { shownName = wanted }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
        guard size > 0 else { throw ToolInputError("The file came back empty.") }
        guard size <= Self.maximumBytes else { throw ToolInputError("The file is \(size / 1_048_576) MB, bigger than MAIPA-G keeps (250 MB).") }
        let reference = try await store.importGeneratedFile(at: file, name: shownName, mimeType: Self.mimeType(shownName))
        let result = GeneratedImageResult(attachment: reference, prompt: shownName, model: "file", aspectRatio: "", quality: "")
        try await store.saveGeneratedMetadata(result)
        return ToolOutput(
            forModel: "Gave the person \(shownName) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) as a file card in the chat. Tell them it's there; don't paste a download link.",
            summary: "Sent \(shownName)",
            generatedImages: [result]
        )
    }

    /// The API address for a GitHub page or download link: an artifact on a run's page
    /// (github.com/o/r/actions/runs/1/artifacts/2) or a release download
    /// (github.com/o/r/releases/download/tag/file), which private repos only serve through the API.
    static func apiDownloadURL(for url: URL, github: GitHubClient) async throws -> String {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.host?.lowercased() == "github.com", parts.count >= 4 else { return url.absoluteString }
        let repo = RepoRef(owner: parts[0], name: parts[1])
        if let index = parts.firstIndex(of: "artifacts"), index + 1 < parts.count, Int(parts[index + 1]) != nil {
            return "https://api.github.com/repos/\(repo.owner)/\(repo.name)/actions/artifacts/\(parts[index + 1])/zip"
        }
        if parts.count >= 6, parts[2] == "releases", parts[3] == "download" {
            let tag = parts[4], name = parts[5...].joined(separator: "/")
            let release = try await github.send("GET", GitHubClient.path(repo, "/releases/tags/\(GitHubClient.escape(tag))"))
            guard let asset = JSONValue.parse(release.body)?["assets"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name }),
                  let id = asset["id"]?.intValue else { throw ToolInputError("The release \(tag) has no file called \(name).") }
            return "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases/assets/\(id)"
        }
        return url.absoluteString
    }

    static func isZip(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// The file to send from inside a zip: the one asked for, the only file, or the only .ipa.
    /// Nil sends the zip itself.
    static func choose(in zip: URL, pick: String?, into folder: URL) throws -> URL? {
        guard let archive = Archive(url: zip, accessMode: .read) else { return nil }
        let files = archive.filter { $0.type == .file && !$0.path.hasPrefix("__MACOSX/") }
        let wanted = pick?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entry: Entry?
        if let wanted, !wanted.isEmpty {
            guard let match = files.first(where: { $0.path.lowercased() == wanted || ($0.path as NSString).lastPathComponent.lowercased() == wanted }) else {
                throw ToolInputError("There's no \(pick ?? "") in the zip. It holds: \(files.prefix(30).map(\.path).joined(separator: ", ")).")
            }
            entry = match
        } else if files.count == 1 {
            entry = files[0]
        } else {
            let ipas = files.filter { $0.path.lowercased().hasSuffix(".ipa") }
            entry = ipas.count == 1 ? ipas[0] : nil
        }
        guard let entry else { return nil }
        let name = (entry.path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), SnapshotStore.isSafeRelativePath(name) else { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        _ = try archive.extract(entry, to: target)
        return target
    }

    static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "ipa": "application/octet-stream"
        case "zip": "application/zip"
        case "pdf": "application/pdf"
        case "deb": "application/vnd.debian.binary-package"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "txt", "md", "log": "text/plain"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

public extension GeneratedImageResult {
    /// A file the AI handed over with send_file (not a picture or video).
    var isFile: Bool { attachment.kind != .image && !isVideo }
}
