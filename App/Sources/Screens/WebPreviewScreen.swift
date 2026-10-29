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

    var body: some View {
        NavigationStack {
            Group {
                if let root = app.previews.directory, let project = app.previews.project {
                    PreviewWebView(root: root, project: project, browser: $browser, coordinator: app.previews)
                } else if app.previews.isLoading { ProgressView("Opening current saved site…") }
                else if let error = app.previews.error {
                    ContentUnavailableView("Preview could not open", systemImage: "safari", description: Text(error))
                        .overlay(alignment: .bottom) {
                            if error.contains("Autonomous") { Button("Build preview with Autonomous") { Task { await app.jobs.start(request: "Build this web project and upload the built site as an artifact named preview-site. Do not deploy it.", repo: repo); dismiss() } }.buttonStyle(.borderedProminent).padding() }
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
                    Button { showDetails = true } label: { Image(systemName: "terminal") }
                    if let url = browser?.currentURL { Link(destination: url) { Image(systemName: "safari") } }
                }
            }
            .task { if app.previews.directory == nil, app.previews.error == nil, !PreviewScenes.isActive { await app.previews.refresh(repo) } }
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
    @Binding var browser: PreviewBrowserModel?
    let coordinator: PreviewCoordinator

    func makeCoordinator() -> Navigation { Navigation(owner: coordinator, browser: browser) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(PreviewSchemeHandler(root: root, entryPath: project.entryPath), forURLScheme: "maipag-preview")
        let script = "window._maipagConsole=[];['log','warn','error'].forEach(k=>{const o=console[k];console[k]=function(...a){window._maipagConsole.push(k+': '+a.join(' '));o.apply(console,a)}});"
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        let model = PreviewBrowserModel(); model.webView = view
        DispatchQueue.main.async { browser = model; context.coordinator.browser = model }
        view.load(URLRequest(url: URL(string: "maipag-preview://site/\(project.entryPath)")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Navigation: NSObject, WKNavigationDelegate {
        weak var owner: PreviewCoordinator?
        weak var browser: PreviewBrowserModel?
        init(owner: PreviewCoordinator, browser: PreviewBrowserModel?) { self.owner = owner; self.browser = browser }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser?.update()
            webView.evaluateJavaScript("window._maipagConsole || []") { [weak self] value, _ in
                guard let messages = value as? [String] else { return }
                Task { @MainActor in messages.forEach { self?.owner?.recordConsole($0) } }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { owner?.recordConsole("error: \(error.localizedDescription)") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { owner?.recordConsole("error: \(error.localizedDescription)") }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            decisionHandler(url.scheme == "maipag-preview" ? .allow : .cancel)
        }
    }
}
