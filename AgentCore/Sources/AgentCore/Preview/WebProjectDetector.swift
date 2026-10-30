import Foundation

public enum WebProjectDetector {
    /// Detects already-built sites first, then common source projects that require a build.
    public static func detect(paths: [String], packageJSON: Data? = nil) -> WebPreviewProject? {
        let files = Set(paths.filter(SnapshotStore.isSafeRelativePath))
        let staticEntries = ["index.html", "public/index.html", "docs/index.html", "site/index.html"]
        if let entry = staticEntries.first(where: files.contains) {
            let root = entry.split(separator: "/").dropLast().joined(separator: "/")
            return WebPreviewProject(kind: .staticSite, entryPath: entry, rootPath: root)
        }
        let builtEntries = ["dist/index.html", "build/index.html", "out/index.html", ".output/public/index.html"]
        if let entry = builtEntries.first(where: files.contains) {
            let root = entry.split(separator: "/").dropLast().joined(separator: "/")
            return WebPreviewProject(kind: .buildArtifact, entryPath: entry, rootPath: root)
        }
        if files.contains("package.json") {
            let command = buildCommand(packageJSON) ?? "npm run build"
            return WebPreviewProject(kind: .buildArtifact, entryPath: "index.html", buildCommand: command, outputDirectories: ["dist", "build", "out", ".output/public"])
        }
        // A web project inside a folder, such as a Vite app in web/ beside native/ code. It is
        // built in that folder; `packageJSON` is that folder's package.json when the caller has it.
        if let folder = packageFolder(in: files) {
            let command = buildCommand(packageJSON) ?? "npm run build"
            return WebPreviewProject(kind: .buildArtifact, entryPath: "index.html", rootPath: folder, buildCommand: command, outputDirectories: ["dist", "build", "out", ".output/public"])
        }
        return nil
    }

    static let preferredFolders = ["web", "site", "app", "frontend", "client", "www", "website", "ui", "webapp", "demo"]

    /// The first-level folder holding a web project's package.json, preferring common web folder
    /// names, then folders with a web bundler config, then the first alphabetically.
    public static func packageFolder(paths: [String]) -> String? {
        packageFolder(in: Set(paths.filter(SnapshotStore.isSafeRelativePath)))
    }

    static func packageFolder(in files: Set<String>) -> String? {
        let folders = files.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard parts.count == 2, parts[1] == "package.json", parts[0] != "node_modules", !parts[0].hasPrefix(".") else { return nil }
            return String(parts[0])
        }.sorted()
        guard !folders.isEmpty else { return nil }
        if let preferred = preferredFolders.first(where: folders.contains) { return preferred }
        let bundlers = ["vite.config.ts", "vite.config.js", "vite.config.mjs", "next.config.js", "next.config.mjs", "next.config.ts", "astro.config.mjs", "svelte.config.js", "index.html"]
        if let configured = folders.first(where: { folder in bundlers.contains { files.contains("\(folder)/\($0)") } }) { return configured }
        return folders.first
    }

    public static func buildCommand(_ data: Data?) -> String? {
        guard let data, let root = JSONValue.parse(data), root["scripts"]?["build"]?.stringValue != nil else { return nil }
        if Set(root["packageManager"]?.stringValue?.split(separator: "@").prefix(1).map(String.init) ?? []).contains("pnpm") { return "pnpm build" }
        if root["packageManager"]?.stringValue?.hasPrefix("yarn@") == true { return "yarn build" }
        return "npm run build"
    }
}
