import AgentCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's free AI on the iPhone (iOS 26 and up, with Apple Intelligence on), for tiny jobs that
/// shouldn't use up OpenRouter requests: naming chats, and judging how hard a request is so Auto
/// knows how much it may spend. Everything here has a plain fallback for when it isn't available.
enum OnDeviceAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it isn't available, in words for Technical details.
    static var status: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "On"
            case .unavailable(let reason): return "Off (\(reason))"
            @unknown default: return "Off"
            }
        }
        return "Needs iOS 26"
        #else
        return "Not in this build"
        #endif
    }

    /// A short title for a chat, or nil when Apple's AI isn't there.
    static func title(message: String, reply: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable else { return nil }
            let prompt = """
            Person: \(message.prefix(700))
            Assistant: \(reply.prefix(500))
            """
            let text = await withTimeout(6) {
                let session = LanguageModelSession(instructions: """
                You give chats short titles. Reply with only the title: 2 to 6 words, in the person's \
                language, no quotes, no full stop.
                """)
                return try? await session.respond(to: prompt).content
            }
            return text.flatMap(cleanTitle)
        }
        #endif
        return nil
    }

    /// How hard a request looks, or nil when Apple's AI isn't there or takes too long.
    static func difficulty(of message: String, hasRepo: Bool) async -> TaskDifficulty? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable else { return nil }
            let prompt = """
            \(hasRepo ? "The person is working on a code repository." : "")
            Request: \(message.prefix(1_200))
            """
            let answer = await withTimeout(1.5) {
                let session = LanguageModelSession(instructions: """
                Sort requests to an AI helper by how hard they are. Reply with exactly one word:
                quick (a greeting, a small question, a short rewrite),
                normal (ordinary coding, writing or explaining),
                hard (planning, design, tricky debugging, reviews, or anything that needs deep thought).
                """)
                return try? await session.respond(to: prompt).content
            }
            guard let word = answer?.lowercased() else { return nil }
            if word.contains("hard") { return .hard }
            if word.contains("quick") { return .quick }
            if word.contains("normal") { return .normal }
            return nil
        }
        #endif
        return nil
    }

    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.components(separatedBy: .newlines).first ?? title
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#`. "))
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !title.isEmpty else { return nil }
        return String(title.prefix(60))
    }

    /// Runs `work`, giving up after `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
