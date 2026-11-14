import Foundation

/// MAIPA-G-data as a reply on the computer reaches it, with a token the phone hands over that
/// can only change that one repo's contents. Two jobs: big files the reply makes go to the files
/// release so the phone gets them from GitHub, and the chat is kept saved there while the phone
/// isn't following the reply (frozen by iOS, closed, or out of signal).
public struct ComputerDataRepo: Sendable {
    let github: GitHubClient
    let repo: RepoRef
    let branch: String?

    public init(github: GitHubClient, repo: RepoRef, branch: String?) {
        self.github = github
        self.repo = repo
        self.branch = branch
    }

    /// Made files at least this big go through GitHub; smaller ones come over the computer's
    /// command tool as before (a few commands).
    public static let relayThreshold = 2 * 1024 * 1024

    /// Uploads `file` to the files release under its SHA-256, unless a finished copy is already there.
    public func relay(_ file: URL) async throws -> RelayedFile {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
        let sha256 = try Hashing.sha256Hex(fileAt: file)
        let name = sha256 + ".bin"
        let release = try await github.filesRelease(repo)
        if let existing = try await github.releaseAssets(repo, releaseID: release).first(where: { $0.name == name && $0.isUploaded && $0.size == size }) {
            return RelayedFile(repo: repo, assetID: existing.id, sha256: sha256, size: size)
        }
        let asset: GitHubClient.ReleaseAsset
        do {
            asset = try await github.uploadReleaseAsset(repo, releaseID: release, name: name, file: file)
        } catch let error as GitHubAPIError where error.status == 409 {
            // A cut-off earlier upload was removed: once more.
            asset = try await github.uploadReleaseAsset(repo, releaseID: release, name: name, file: file)
        }
        return RelayedFile(repo: repo, assetID: asset.id, sha256: sha256, size: size)
    }

    /// Saves `chat` as `chats/<id>.json`, the way the phone does, but only over a copy already
    /// there: a chat the person deleted is never put back. True when it was saved.
    @discardableResult
    public func saveChat(_ chat: Chat) async throws -> Bool {
        let path = ChatStore.relativePath(for: chat.id)
        let encoded = try JSONCoding.encoder(pretty: true).encode(chat)
        let data = try SensitiveDataRedactor().redactJSON(encoded)
        let branch = try await resolvedBranch()
        for _ in 0..<3 {
            guard let head = try await github.branchHead(repo, branch: branch) else { return false }
            let exists = try await github.send("GET", GitHubClient.path(repo, "/contents/\(path)"), query: ["ref": head], allow: [404])
            guard exists.isSuccess else { return false }
            let tree = try await github.commitTree(repo, commit: head)
            let blob = try await github.createBlob(repo, contents: data)
            let newTree = try await github.createTree(repo, base: tree, changes: [GitHubClient.TreeChange(path: path, blobSHA: blob)])
            let commit = try await github.createCommit(repo, message: "Save 1 chat", tree: newTree, parents: [head])
            do {
                try await github.updateBranch(repo, branch: branch, to: commit)
                return true
            } catch let error as GitHubAPIError where error.status == 409 || error.status == 422 {
                // The phone saved at the same moment: build on its commit instead.
                continue
            }
        }
        return false
    }

    private func resolvedBranch() async throws -> String {
        if let branch, !branch.isEmpty { return branch }
        return try await github.repository(repo).defaultBranch
    }
}

/// Keeps the chat saved in MAIPA-G-data from the computer while nobody follows the reply on the
/// phone: the phone marks each look at the reply (`phone-seen` in the run's folder), and when it
/// hasn't looked for `awayAfter`, the chat as it is now is saved every `every` seconds and once
/// more at the end. While the phone follows, the phone saves it, so it isn't saved twice.
public actor RunningChatSaver {
    let dataRepo: ComputerDataRepo
    let folder: URL
    let awayAfter: TimeInterval
    let every: TimeInterval
    private var lastSaved: Date
    private var lastSavedSteps = -1
    private var saving = false

    public init(dataRepo: ComputerDataRepo, folder: URL, awayAfter: TimeInterval = 180, every: TimeInterval = 300, startedAt: Date = Date()) {
        self.dataRepo = dataRepo
        self.folder = folder
        self.awayAfter = awayAfter
        self.every = every
        self.lastSaved = startedAt
    }

    public static let phoneSeenFile = "phone-seen"

    /// When the phone last read the reply's state (it touches the file with each look).
    nonisolated func phoneLastSeen() -> Date? {
        let url = folder.appendingPathComponent(Self.phoneSeenFile)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    nonisolated func phoneIsAway(now: Date = Date()) -> Bool {
        guard let seen = phoneLastSeen() else { return true }
        return now.timeIntervalSince(seen) > awayAfter
    }

    /// Saves `chat` (the reply's chat with `turn` in it) when the phone is away and it is time.
    /// `final` saves the finished reply whenever the phone is away.
    public func step(chat: Chat, turn: AssistantTurn, runID: String, final: Bool = false, now: Date = Date()) async {
        guard !saving, phoneIsAway(now: now) else { return }
        guard final || (now.timeIntervalSince(lastSaved) >= every && turn.steps.count != lastSavedSteps) else { return }
        saving = true
        defer { saving = false }
        var saved = chat
        if let last = saved.messages.indices.last, saved.messages[last].assistantTurn != nil {
            saved.messages[last].assistantTurn = turn
        } else {
            saved.messages.append(ChatMessage(body: .assistant(turn)))
        }
        // Still running: the phone that opens it follows the reply here instead of running it again.
        saved.computerRunID = turn.status == .running ? runID : nil
        saved.updatedAt = now
        if (try? await dataRepo.saveChat(saved)) == true {
            lastSaved = now
            lastSavedSteps = turn.steps.count
        }
    }
}
