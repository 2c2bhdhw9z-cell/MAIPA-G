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
        guard files.contains("package.json") else { return nil }
        let command = buildCommand(packageJSON) ?? "npm run build"
        return WebPreviewProject(kind: .buildArtifact, entryPath: "index.html", buildCommand: command, outputDirectories: ["dist", "build", "out", ".output/public"])
    }

    private static func buildCommand(_ data: Data?) -> String? {
        guard let data, let root = JSONValue.parse(data), root["scripts"]?["build"]?.stringValue != nil else { return nil }
        if Set(root["packageManager"]?.stringValue?.split(separator: "@").prefix(1).map(String.init) ?? []).contains("pnpm") { return "pnpm build" }
        if root["packageManager"]?.stringValue?.hasPrefix("yarn@") == true { return "yarn build" }
        return "npm run build"
    }
}
