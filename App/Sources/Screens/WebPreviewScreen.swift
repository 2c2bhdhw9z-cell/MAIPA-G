import AgentCore
import Observation
import SwiftUI
import WebKit

struct WebPreviewScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let repo: ChatRepo
    @State private var browser: PreviewBrowserModel?
    @State private var showDetails = false
    @State private var showHostEntry = false
    @State private var hostEntry = ""
    @State private var hostError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let root = app.previews.directory, let project = app.previews.project, let manifest = app.previews.manifest {
                    PreviewWebView(root: root, project: project, manifest: manifest, browser: $browser, coordinator: app.previews)
                } else if app.previews.isLoading { ProgressView("Opening current saved site…") }
                else if let error = app.previews.error {
                    ContentUnavailableView("Preview could not open", systemImage: "safari", description: Text(error))
                        .overlay(alignment: .bottom) {
                            if app.previews.buildProject != nil {
                                Button("Build preview with Autonomous") {
                                    Task { if await app.previews.build(repo) { dismiss() } }
                                }
                                .buttonStyle(.borderedProminent).padding()
                            }
                        }
                } else { ProgressView() }
            }
            .navigationTitle("Live preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { browser?.back() } label: { Image(systemName: "chevron.backward") }.disabled(browser?.canGoBack != true)
                    Button { browser?.forward() } label: { Image(systemName: "chevron.forward") }.disabled(browser?.canGoForward != true)
                    Button { browser?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Button { Task { await app.previews.refresh(repo); browser?.reload() } } label: { Image(systemName: "externaldrive.badge.icloud") }
                    Spacer()
                    Button { showHostEntry = true } label: { Image(systemName: "network") }
                        .accessibilityLabel("Allow preview network host")
                    Button { showDetails = true } label: { Image(systemName: "terminal") }
                    if let url = browser?.currentURL { Link(destination: url) { Image(systemName: "safari") } }
                }
            }
            .task { if app.previews.directory == nil, app.previews.error == nil, !PreviewScenes.isActive { await app.previews.refresh(repo) } }
            .alert("Allow one HTTPS host", isPresented: $showHostEntry) {
                TextField("api.example.com", text: $hostEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Allow") {
                    do {
                        try app.allowPreviewHost(hostEntry, for: repo.ref)
                        Task { await app.previews.refresh(repo); browser?.reload() }
                    } catch { hostError = ErrorExplainer.explain(error).message }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Preview network access is blocked by default. This allows only the exact host you enter.")
            }
            .alert("Host not allowed", isPresented: Binding(get: { hostError != nil }, set: { if !$0 { hostError = nil } })) {
                Button("OK") {}
            } message: { Text(hostError ?? "") }
            .sheet(isPresented: $showDetails) {
                NavigationStack {
                    List(app.previews.console, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                        .navigationTitle("Preview messages")
                }
            }
        }
    }
}

@MainActor
@Observable
final class PreviewBrowserModel {
    weak var webView: WKWebView?
    var canGoBack = false
    var canGoForward = false
    var currentURL: URL?
    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func update() { canGoBack = webView?.canGoBack == true; canGoForward = webView?.canGoForward == true; currentURL = webView?.url }
}

struct PreviewWebView: UIViewRepresentable {
    let root: URL
    let project: WebPreviewProject
    let manifest: PublishedPreviewManifest
    @Binding var browser: PreviewBrowserModel?
    let coordinator: PreviewCoordinator

    func makeCoordinator() -> Navigation { Navigation(owner: coordinator, browser: browser) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(PreviewSchemeHandler(root: root, manifest: manifest), forURLScheme: "maipag-preview")
        let script = "window._maipagConsole=[];['log','warn','error'].forEach(k=>{const o=console[k];console[k]=function(...a){window._maipagConsole.push(k+': '+a.join(' '));o.apply(console,a)}});"
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        // WebKit's block lists don't accept "|" in a filter (the old "^(https?|wss?)://" never
        // compiled, so no list was ever installed), and "unless-domain" means the page's own
        // domain, not the request's. So: block every web and socket address, then let only the
        // owner's allowed hosts through with later "ignore-previous-rules" rules.
        var rules: [[String: Any]] = ["^https?://", "^wss?://"].map { filter -> [String: Any] in
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        for host in manifest.allowedHTTPSHosts.sorted() {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            for scheme in ["https", "wss"] {
                rules.append(["trigger": ["url-filter": "^\(scheme)://\(escaped)[:/]"], "action": ["type": "ignore-previous-rules"]])
            }
        }
        view.navigationDelegate = context.coordinator
        let model = PreviewBrowserModel(); model.webView = view
        DispatchQueue.main.async { browser = model; context.coordinator.browser = model }
        let entry = URL(string: "maipag-preview://site/\(project.entryPath)")!
        let owner = coordinator
        // The page loads only after the network block list is in place, so not even its first
        // script runs without it. If the list can't be built, the page doesn't load at all.
        if let data = try? JSONSerialization.data(withJSONObject: rules),
           let source = String(data: data, encoding: .utf8) {
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "maipag-preview-\(manifest.allowedHTTPSHosts.sorted().joined(separator: "-"))", encodedContentRuleList: source) { list, error in
                Task { @MainActor in
                    guard let list else {
                        owner.recordConsole("error: the preview's network block list couldn't be built (\(error?.localizedDescription ?? "unknown")), so the page wasn't opened.")
                        return
                    }
                    view.configuration.userContentController.add(list)
                    view.load(URLRequest(url: entry))
                }
            }
        } else {
            owner.recordConsole("error: the preview's network block list couldn't be built, so the page wasn't opened.")
        }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Navigation: NSObject, WKNavigationDelegate {
        weak var owner: PreviewCoordinator?
        weak var browser: PreviewBrowserModel?
        init(owner: PreviewCoordinator, browser: PreviewBrowserModel?) { self.owner = owner; self.browser = browser }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser?.update()
            collectConsole(webView)
            // Messages a page logs after it finishes loading are collected a little later too.
            for delay in [3.0, 6.0, 10.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let webView else { return }
                    self?.collectConsole(webView)
                }
            }
        }

        private func collectConsole(_ webView: WKWebView) {
            webView.evaluateJavaScript("window._maipagConsole || []") { [weak self] value, _ in
                guard let messages = value as? [String] else { return }
                Task { @MainActor in messages.forEach { self?.owner?.recordConsole($0) } }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { owner?.recordConsole("error: \(error.localizedDescription)") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { owner?.recordConsole("error: \(error.localizedDescription)") }
        // Must match the SDK's signature exactly, or WebKit never calls it and the preview could
        // leave its own files.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            decisionHandler(url.scheme == "maipag-preview" ? .allow : .cancel)
        }
    }
}
