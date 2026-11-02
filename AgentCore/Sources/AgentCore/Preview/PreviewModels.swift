import Foundation
import ZIPFoundation

public enum WebPreviewKind: String, Codable, Sendable, Hashable { case staticSite, buildArtifact }

public struct WebPreviewProject: Codable, Sendable, Hashable {
    public var kind: WebPreviewKind
    public var entryPath: String
    public var rootPath: String
    public var buildCommand: String?
    public var outputDirectories: [String]
    public init(kind: WebPreviewKind, entryPath: String, rootPath: String = "", buildCommand: String? = nil, outputDirectories: [String] = []) {
        self.kind = kind; self.entryPath = entryPath; self.rootPath = rootPath
        self.buildCommand = buildCommand; self.outputDirectories = outputDirectories
    }
}

/// Resolves static asset/page references while publishing a private repository's root-level
/// preview. Only explicitly referenced, safe, tracked files are returned.
public enum PreviewAssetResolver {
    public static func referencedFiles(in source: String, from entryPath: String) -> Set<String> {
        var references = matches(#"(?i)(?:src|href|poster)\s*=\s*(['"])(.*?)\1"#, group: 2, in: source)
        references += matches(#"(?i)srcset\s*=\s*(['"])(.*?)\1"#, group: 2, in: source)
            .flatMap { $0.split(separator: ",").compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map { String($0) } } }
        references += matches(#"(?i)url\(\s*(['"]?)(.*?)\1\s*\)"#, group: 2, in: source)
        references += matches(#"(?i)@import\s+(['"])(.*?)\1"#, group: 2, in: source)
        references += matches(#"(?m)\b(?:import|export)\s+[^;\n]*?\s+from\s+(['"])(.*?)\1"#, group: 2, in: source)
        references += matches(#"(?m)\bimport\s*\(\s*(['"])(.*?)\1\s*\)"#, group: 2, in: source)
        references += matches(#"(?m)\bimport\s+(['"])(.*?)\1"#, group: 2, in: source)
        return Set(references.compactMap { resolve($0, from: entryPath) })
    }

    private static func matches(_ pattern: String, group: Int, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > group, let range = Range(match.range(at: group), in: source) else { return nil }
            return String(source[range])
        }
    }

    private static func resolve(_ reference: String, from entryPath: String) -> String? {
        var value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("//"),
              value.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        value = String(value.prefix { $0 != "?" && $0 != "#" })
        guard !value.isEmpty else { return nil }
        if let decoded = value.removingPercentEncoding { value = decoded }
        else if value.contains("%") { return nil }
        guard !value.contains("\\") else { return nil }

        var parts = value.hasPrefix("/") ? [] : Array(entryPath.split(separator: "/").dropLast().map(String.init))
        for component in value.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        let path = parts.joined(separator: "/")
        guard SnapshotStore.isSafeRelativePath(path), !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return path
    }
}

public struct PublishedPreviewManifest: Codable, Sendable, Hashable {
    public var entryPath: String
    public var files: Set<String>
    public var allowedHTTPSHosts: Set<String>

    public init(entryPath: String, files: Set<String>, allowedHTTPSHosts: Set<String> = []) {
        self.entryPath = entryPath
        self.files = files
        self.allowedHTTPSHosts = Set(allowedHTTPSHosts.map { $0.lowercased() })
    }

    public func allows(_ path: String) -> Bool { files.contains(path) }

    public var contentSecurityPolicy: String {
        let hosts = allowedHTTPSHosts.sorted().map { "https://\($0)" }.joined(separator: " ")
        let connect = hosts.isEmpty ? "'none'" : hosts
        return "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: \(hosts); font-src 'self' data:; connect-src \(connect); form-action 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'"
    }
}

public enum PreviewArtifactExtractor {
    public static func extract(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let archiveURL = destination.appendingPathComponent("artifact.zip")
        try data.write(to: archiveURL, options: .atomic)
        guard let archive = Archive(url: archiveURL, accessMode: .read) else { throw WebPreviewError.missingResource("preview artifact") }
        for entry in archive {
            let clean = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard SnapshotStore.isSafeRelativePath(clean), entry.type != .symlink else { throw WebPreviewError.unsafePath }
            let target = destination.appendingPathComponent(clean)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }
        try? manager.removeItem(at: archiveURL)
    }
}

public enum WebPreviewError: Error, Sendable, CustomStringConvertible {
    case noWebEntryPoint
    case buildRequired(command: String)
    case unsafePath
    case missingResource(String)
    public var description: String {
        switch self {
        case .noWebEntryPoint: return "No website entry point was found in this project."
        case .buildRequired(let command): return "This website must be built first with Autonomous: \(command)"
        case .unsafePath: return "The preview blocked a path outside the site."
        case .missingResource(let path): return "The preview could not find \(path)."
        }
    }
}

/// Resolves custom-scheme requests without allowing `..`, encoded traversal, or host escapes.
public enum PreviewPath {
    public static func relativePath(for url: URL, root: String, spaFallback: String) throws -> String {
        guard url.scheme == "maipag-preview" else { throw WebPreviewError.unsafePath }
        let decoded = url.path.removingPercentEncoding ?? url.path
        var path = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { path = spaFallback }
        guard SnapshotStore.isSafeRelativePath(path), !path.split(separator: "/").contains("..") else { throw WebPreviewError.unsafePath }
        let prefix = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = prefix.isEmpty ? path : "\(prefix)/\(path)"
        guard SnapshotStore.isSafeRelativePath(full) else { throw WebPreviewError.unsafePath }
        return full
    }

    public static func mimeType(for path: String) -> String {
        switch path.split(separator: ".").last?.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
