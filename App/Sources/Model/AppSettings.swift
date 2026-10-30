import AgentCore
import Foundation

enum Appearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }
}

/// The main colour of buttons, highlights and Spark's glow.
enum AccentChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case mint, sky, violet, rose, coral, gold
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// The gentle moving effects. Each has its own switch, and all start on. iOS's Reduce Motion
/// setting turns them all off, whatever these say.
struct Effects: Codable, Equatable, Sendable {
    /// Spark floats and blinks.
    var sparkMoves = true
    /// Soft colour drifts behind the home screen.
    var backgroundGlow = true
    /// "Thinking" shimmers while the AI thinks.
    var thinkingShimmer = true
    /// New messages slide in.
    var messagesSlideIn = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sparkMoves = try c.decodeIfPresent(Bool.self, forKey: .sparkMoves) ?? true
        backgroundGlow = try c.decodeIfPresent(Bool.self, forKey: .backgroundGlow) ?? true
        thinkingShimmer = try c.decodeIfPresent(Bool.self, forKey: .thinkingShimmer) ?? true
        messagesSlideIn = try c.decodeIfPresent(Bool.self, forKey: .messagesSlideIn) ?? true
    }
}

enum WorkflowPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case whenAsked
    case bigJobs
    case everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .whenAsked: return "When asked"
        case .bigJobs: return "Big jobs too"
        case .everything: return "Everything"
        }
    }
}

/// Everything set in Settings. Saved as settings.json and kept in MAIPA-G-data with the chats, so
/// deleting the app loses none of it. Fields added in later builds get their defaults when an
/// older file is read.
struct AppSettings: Codable, Equatable, Sendable {
    /// For telling which copy is newer when the phone and GitHub both changed.
    var updatedAt = Date(timeIntervalSince1970: 0)
    var appearance: Appearance = .system
    var accent: AccentChoice = .mint
    var effects = Effects()
    /// "Stop and ask when a job has cost $__". Off to start with, as Kiro has no such stop.
    var spendLimitOn = false
    var spendLimit: Double = 1
    /// The repo the last new chat used, so the next one starts there too.
    var lastRepo: ChatRepo?
    /// Local finish/needs-answer notifications start on.
    var notificationsOn = true
    /// Repos whose changes save straight to the selected branch.
    var directSaveRepos: [String: Bool] = [:]
    /// When work moves to an Autonomous GitHub runner. Big jobs too is the factory default.
    var workflowPolicy: WorkflowPolicy = .bigJobs
    /// Global Autonomous switch. Turning it off removes MAIPA-G-managed Actions secrets.
    var autonomousEnabled = true
    /// Master switch for adding enabled memories to newly started chats.
    var memoriesOn = true
    /// The connector (its serverID) that gives chats a Linux computer to run commands on. Nil is
    /// Automatic: the first connected connector on sprites.dev.
    var chatComputerServer: String?
    /// No computer for chats, whatever is connected.
    var chatComputerOff = false
    /// The machine chats use on that computer. Sprites' default sign-in only allows names that
    /// start with mcp-.
    var chatComputerMachine = AppSettings.defaultChatComputerMachine
    /// Exact HTTPS hosts explicitly allowed for each repository preview.
    var previewAllowedHosts: [String: Set<String>] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? .system
        accent = (try? c.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? .mint
        effects = (try? c.decodeIfPresent(Effects.self, forKey: .effects)) ?? Effects()
        spendLimitOn = try c.decodeIfPresent(Bool.self, forKey: .spendLimitOn) ?? false
        spendLimit = try c.decodeIfPresent(Double.self, forKey: .spendLimit) ?? 1
        lastRepo = try? c.decodeIfPresent(ChatRepo.self, forKey: .lastRepo)
        notificationsOn = try c.decodeIfPresent(Bool.self, forKey: .notificationsOn) ?? true
        directSaveRepos = try c.decodeIfPresent([String: Bool].self, forKey: .directSaveRepos) ?? [:]
        workflowPolicy = (try? c.decodeIfPresent(WorkflowPolicy.self, forKey: .workflowPolicy)) ?? .bigJobs
        autonomousEnabled = try c.decodeIfPresent(Bool.self, forKey: .autonomousEnabled) ?? true
        memoriesOn = try c.decodeIfPresent(Bool.self, forKey: .memoriesOn) ?? true
        chatComputerServer = try? c.decodeIfPresent(String.self, forKey: .chatComputerServer)
        chatComputerOff = (try? c.decodeIfPresent(Bool.self, forKey: .chatComputerOff)) ?? false
        chatComputerMachine = (try? c.decodeIfPresent(String.self, forKey: .chatComputerMachine)) ?? AppSettings.defaultChatComputerMachine
        previewAllowedHosts = (try? c.decodeIfPresent([String: Set<String>].self, forKey: .previewAllowedHosts)) ?? [:]
    }

    func savesDirectly(to repo: RepoRef) -> Bool { directSaveRepos[repo.fullName] ?? false }

    static let defaultChatComputerMachine = "mcp-maipa-g"
    private static let machineNameAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    /// What a machine name may hold while it is typed: lowercase letters, digits and dashes.
    static func machineNameCharacters(_ typed: String) -> String {
        typed.lowercased().filter { machineNameAllowed.contains($0) }
    }

    /// The machine name chats really use: the typed one without other characters or end dashes,
    /// or mcp-maipa-g when nothing is left.
    var chatComputerMachineName: String {
        let clean = Self.machineNameCharacters(chatComputerMachine).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return clean.isEmpty ? Self.defaultChatComputerMachine : clean
    }

    static let fileName = "settings.json"
}
