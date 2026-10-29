import AgentCore
import Foundation
import WebKit

final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    let root: URL
    let entryPath: String
    init(root: URL, entryPath: String) { self.root = root.standardizedFileURL; self.entryPath = entryPath }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url else { throw WebPreviewError.unsafePath }
            var relative = try PreviewPath.relativePath(for: url, root: "", spaFallback: entryPath)
            var target = root.appendingPathComponent(relative).standardizedFileURL
            if !FileManager.default.fileExists(atPath: target.path), target.pathExtension.isEmpty {
                relative = entryPath; target = root.appendingPathComponent(entryPath).standardizedFileURL
            }
            let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
            guard target.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot), FileManager.default.fileExists(atPath: target.path) else { throw WebPreviewError.missingResource(relative) }
            let data = try Data(contentsOf: target, options: .mappedIfSafe)
            guard data.count <= 25 * 1024 * 1024 else { throw WebPreviewError.missingResource("a resource larger than 25 MB") }
            let response = URLResponse(url: url, mimeType: PreviewPath.mimeType(for: relative), expectedContentLength: data.count, textEncodingName: relative.hasSuffix(".html") || relative.hasSuffix(".css") || relative.hasSuffix(".js") ? "utf-8" : nil)
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
