import AgentCore
import Foundation
import WebKit

final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    let root: URL
    let manifest: PublishedPreviewManifest
    var entryPath: String { manifest.entryPath }
    init(root: URL, manifest: PublishedPreviewManifest) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url else { throw WebPreviewError.unsafePath }
            var relative = try PreviewPath.relativePath(for: url, root: "", spaFallback: entryPath)
            var target = root.appendingPathComponent(relative).standardizedFileURL
            if !FileManager.default.fileExists(atPath: target.path), target.pathExtension.isEmpty {
                relative = entryPath; target = root.appendingPathComponent(entryPath).standardizedFileURL
            }
            let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
            guard manifest.allows(relative),
                  target.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
                  FileManager.default.fileExists(atPath: target.path)
            else { throw WebPreviewError.missingResource(relative) }
            let data = try Data(contentsOf: target, options: .mappedIfSafe)
            guard data.count <= 25 * 1024 * 1024 else { throw WebPreviewError.missingResource("a resource larger than 25 MB") }
            let headers = [
                "Content-Type": PreviewPath.mimeType(for: relative),
                "Content-Security-Policy": manifest.contentSecurityPolicy,
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
            ]
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw WebPreviewError.missingResource(relative)
            }
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
