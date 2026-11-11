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

/// How the chat behaves when you type. Two modes, no third.
///
/// **Vibe** just does it. **Spec** writes the requirements and a plan first, shows them, and builds
/// after you say go. Both words are ordinary English — "vibe coding" was coined by Andrej Karpathy
/// in February 2025, and "spec" is short for specification — so neither name belongs to another
/// app. The mode is a hint, not a cage: the chat can still decide a plain request needs a plan.
enum ChatMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case vibe
    case spec

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vibe: return "Vibe"
        case .spec: return "Spec"
        }
    }

    /// One line, in plain words, for the picker.
    var explanation: String {
        switch self {
        case .vibe: return "just does it"
        case .spec: return "writes the plan first, then builds once you say go"
        }
    }

    var symbolName: String {
        switch self {
        case .vibe: return "bolt"
        case .spec: return "list.bullet.rectangle"
        }
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
    /// Repos whose changes save straight to the selected branch (or, when false, as a pull
    /// request), overriding `saveStraightToBranchEverywhere` for that repo.
    var directSaveRepos: [String: Bool] = [:]
    /// What the person said about every repo: true for straight to the branch, false for pull
    /// requests, nil when they haven't said (pull requests, Kiro's factory default).
    var saveStraightToBranchEverywhere: Bool?
    /// When work moves to an Autonomous GitHub runner. Big jobs too is the factory default.
    var workflowPolicy: WorkflowPolicy = .bigJobs
    /// Workflows off means nothing can start a workflow from anywhere and the chat answers plainly.
    /// Off to start with, because these have never been used and it is not known that they work.
    var workflowsEnabled = false
    /// Specs off hides Spec from the mode picker and makes the chat plan inline instead.
    var specsEnabled = false
    /// Global Autonomous switch. Turning it off removes MAIPA-G-managed Actions secrets.
    /// Off to start with, so the app behaves like a plain chat with a repo until it is turned on.
    var autonomousEnabled = false
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
    var chatComputerHourlyCost: Double = 0.10
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
        saveStraightToBranchEverywhere = try? c.decodeIfPresent(Bool.self, forKey: .saveStraightToBranchEverywhere)
        workflowPolicy = (try? c.decodeIfPresent(WorkflowPolicy.self, forKey: .workflowPolicy)) ?? .bigJobs
        workflowsEnabled = try c.decodeIfPresent(Bool.self, forKey: .workflowsEnabled) ?? false
        specsEnabled = try c.decodeIfPresent(Bool.self, forKey: .specsEnabled) ?? false
        autonomousEnabled = try c.decodeIfPresent(Bool.self, forKey: .autonomousEnabled) ?? false
        memoriesOn = try c.decodeIfPresent(Bool.self, forKey: .memoriesOn) ?? true
        chatComputerServer = try? c.decodeIfPresent(String.self, forKey: .chatComputerServer)
        chatComputerOff = (try? c.decodeIfPresent(Bool.self, forKey: .chatComputerOff)) ?? false
        chatComputerMachine = (try? c.decodeIfPresent(String.self, forKey: .chatComputerMachine)) ?? AppSettings.defaultChatComputerMachine
        chatComputerHourlyCost = try c.decodeIfPresent(Double.self, forKey: .chatComputerHourlyCost) ?? 0.10
        previewAllowedHosts = (try? c.decodeIfPresent([String: Set<String>].self, forKey: .previewAllowedHosts)) ?? [:]
    }

    func savesDirectly(to repo: RepoRef) -> Bool { directSaveRepos[repo.settingsKey] ?? saveStraightToBranchEverywhere ?? false }

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
