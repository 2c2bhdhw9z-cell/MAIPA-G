import AgentCore
import SwiftUI
import WebKit

/// The app being built, running live on the chat computer (app_preview), the way Rork and
/// VibeCode show it: inside MAIPA-G, and for an Expo app also in Expo Go with one tap. It reloads
/// by itself when the AI's changes reach the computer.
struct LivePreviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let link: LivePreviewLink
    @State private var reloadToken = 0
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LivePreviewWebView(url: URL(string: link.webURL), reloadToken: reloadToken, loading: $loading, failure: $failure, openOutside: { openURL($0) })
                    .ignoresSafeArea(edges: .bottom)
                if loading {
                    ProgressView("Opening the preview…")
                        .padding()
                        .glassPanel()
                }
                if let failure {
                    ContentUnavailableView {
                        Label("The preview didn't open", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { self.failure = nil; reloadToken += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                    .background(Theme.background)
                }
            }
            .navigationTitle(link.kind == "expo" ? "App preview" : "Live preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { failure = nil; reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload the preview")
                    if let expo = link.expoGoURL, let url = URL(string: expo) {
                        Button { openURL(url) } label: { Label("Expo Go", systemImage: "iphone.gen3") }
                            .accessibilityLabel("Open in Expo Go")
                    }
                }
            }
        }
    }
}

private struct LivePreviewWebView: UIViewRepresentable {
    let url: URL?
    let reloadToken: Int
    @Binding var loading: Bool
    @Binding var failure: String?
    let openOutside: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.lastToken = reloadToken
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        if let url { view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LivePreviewWebView
        var lastToken = 0
        init(_ parent: LivePreviewWebView) { self.parent = parent }

        /// The preview's own address stays in here; a link to anywhere else opens in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            let ownHost = parent.url?.host
            if target.host == ownHost || ["about", "blob", "data"].contains(target.scheme ?? "") || action.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                parent.openOutside(target)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.failure = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            if (error as NSError).code != NSURLErrorCancelled { parent.failure = Self.explain(error) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            if (error as NSError).code != NSURLErrorCancelled { parent.failure = Self.explain(error) }
        }

        static func explain(_ error: Error) -> String {
            let code = (error as NSError).code
            if code == NSURLErrorCannotFindHost || code == NSURLErrorCannotConnectToHost {
                return "The preview has stopped (it stops after two hours, or when the computer restarts). Ask in the chat to start it again."
            }
            return error.localizedDescription
        }
    }
}

/// The card a started preview leaves in the chat.
struct LivePreviewCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let link: LivePreviewLink

    private var probablyStopped: Bool { Date().timeIntervalSince(link.startedAt) > Double(AppPreview.lifetimeSeconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: link.kind == "expo" ? "iphone.gen3" : "safari")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.kind == "expo" ? "Your app, running live" : "Your site, running live").font(.subheadline.weight(.semibold))
                    Text(probablyStopped ? "This preview has stopped. Ask to start it again." : "Updates as changes reach your computer")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if !probablyStopped {
                HStack {
                    Button {
                        app.sheet = .livePreview(link)
                    } label: {
                        Label("Open preview", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    if let expo = link.expoGoURL, let url = URL(string: expo) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Expo Go", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
