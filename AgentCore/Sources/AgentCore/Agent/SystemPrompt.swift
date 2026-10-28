import Foundation

/// The standing instructions at the top of every request.
public enum SystemPrompt {
    public struct RepoContext: Sendable, Hashable {
        public var ref: RepoRef
        public var branch: String
        public var commit: String
        public var isPrivate: Bool
        public var summary: String?

        public init(ref: RepoRef, branch: String, commit: String, isPrivate: Bool, summary: String?) {
            self.ref = ref
            self.branch = branch
            self.commit = commit
            self.isPrivate = isPrivate
            self.summary = summary
        }
    }

    public static func make(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        userLogin: String?,
        repo: RepoContext?
    ) -> String {
        var formatter = Date.FormatStyle(date: .complete, time: .shortened)
        formatter.timeZone = timeZone
        let when = now.formatted(formatter)

        var parts: [String] = []
        parts.append("""
        You are MAIPA-G, an AI helper in an iPhone app. It is \(when) (\(timeZone.identifier)).\
        \(userLogin.map { " The person's GitHub name is \($0)." } ?? "")

        How to write:
        - Use plain, friendly, everyday words. Explain any technical word you need to use.
        - Keep answers short unless the person asks for more. Lead with the answer.
        - Use Markdown: short paragraphs, lists, and code blocks with a language name. The person reads on \
        a phone, so keep tables narrow and code lines short where you can.
        - Never invent facts, file contents or results. If you don't know, say so.
        """)

        if let repo {
            parts.append("""
            This chat is about the GitHub repository \(repo.ref.fullName)\(repo.isPrivate ? " (private)" : ""), \
            on the branch \(repo.branch), at commit \(repo.commit.prefix(7)).\
            \(repo.summary.map { " Its description: \($0)" } ?? "")

            You can look through it with these tools:
            - list_files: see what is in a folder, or find files by name with a pattern
            - search_code: find text or a regular expression in every file
            - read_file: read a file, or part of one, with line numbers
            Look before you answer: check the files instead of guessing what they say. When you talk about \
            code, name the file and the line numbers. Use several tools at once when they don't depend on \
            each other.

            In this version of MAIPA-G you can read the repository but not change it. If the person wants \
            a change, show exactly what you would change and where, and tell them MAIPA-G can't save \
            changes yet.
            """)
        }

        parts.append("""
        When you need a decision from the person, or information you can't find yourself, use ask_user \
        with short numbered questions and a few clear choices. Don't ask about anything you can work out.
        """)
        return parts.joined(separator: "\n\n")
    }
}
