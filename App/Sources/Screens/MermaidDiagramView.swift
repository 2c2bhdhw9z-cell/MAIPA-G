import SwiftUI
import UIKit
import WebKit

@MainActor
private enum MermaidBundle {
    static let userScript: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()
}

/// Renders a ```mermaid diagram offline with pan/zoom, full-screen inspection, and a Chart/Code toggle.
struct MermaidBlockView: View {
    var code: String
    @State private var showCode = false
    @State private var copied = false
    @State private var showingFullScreen = false
    @State private var diagramHeight: CGFloat = 280
    @State private var renderFailed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text("Diagram")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                HStack(spacing: 2) {
                    modeButton(title: "Chart", selected: !showCode && !renderFailed) {
                        renderFailed = false
                        showCode = false
                    }
                    modeButton(title: "Code", selected: showCode || renderFailed) {
                        showCode = true
                    }
                }
                .padding(2)
                .background(Theme.surface, in: Capsule())

                if !showCode && !renderFailed {
                    Button {
                        showingFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Full screen diagram")
                }

                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptics.selection()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.5))

            if showCode || renderFailed || MermaidBundle.userScript == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                MermaidWebCanvas(
                    code: code,
                    isDark: colorScheme == .dark,
                    allowZoom: true,
                    reportedHeight: $diagramHeight,
                    renderFailed: $renderFailed
                )
                .frame(height: min(max(diagramHeight, 180), 440))
            }
        }
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        .sheet(isPresented: $showingFullScreen) {
            MermaidFullScreenSheet(code: code, isDark: colorScheme == .dark)
        }
    }

    private func modeButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(selected ? .primary : Theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? Theme.raised : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct MermaidFullScreenSheet: View {
    let code: String
    let isDark: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 600
    @State private var failed = false

    var body: some View {
        NavigationStack {
            MermaidWebCanvas(
                code: code,
                isDark: isDark,
                allowZoom: true,
                fullScreen: true,
                reportedHeight: $height,
                renderFailed: $failed
            )
            .ignoresSafeArea(edges: .bottom)
            .background(Theme.background)
            .navigationTitle("Diagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = code
                        Haptics.selection()
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct MermaidWebCanvas: UIViewRepresentable {
    var code: String
    var isDark: Bool
    var allowZoom: Bool
    var fullScreen: Bool = false
    @Binding var reportedHeight: CGFloat
    @Binding var renderFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        if let script = MermaidBundle.userScript {
            controller.addUserScript(script)
        }
        controller.add(context.coordinator, name: "mermaidBridge")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = true
        webView.scrollView.minimumZoomScale = 0.5
        webView.scrollView.maximumZoomScale = fullScreen ? 6.0 : 3.5
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadIfNeeded(in: webView, code: code, isDark: isDark, fullScreen: fullScreen)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(in: webView, code: code, isDark: isDark, fullScreen: fullScreen)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidBridge")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MermaidWebCanvas
        private var lastKey: String?

        init(parent: MermaidWebCanvas) {
            self.parent = parent
        }

        func loadIfNeeded(in webView: WKWebView, code: String, isDark: Bool, fullScreen: Bool) {
            let key = "\(isDark)-\(fullScreen)-\(code)"
            guard key != lastKey else { return }
            lastKey = key
            webView.loadHTMLString(Self.html(code: code, isDark: isDark, fullScreen: fullScreen), baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let dict = message.body as? [String: Any]
            let heightValue = (dict?["height"] as? Double) ?? (dict?["height"] as? Int).map(Double.init)
            let failedValue = (dict?["error"] as? Bool) ?? false
            if failedValue {
                parent.renderFailed = true
            } else if let heightValue, heightValue > 20 {
                parent.renderFailed = false
                parent.reportedHeight = CGFloat(heightValue)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let isAboutBlank = action.request.url?.absoluteString == "about:blank" || action.navigationType == .other
            decisionHandler(isAboutBlank ? .allow : .cancel)
        }

        private static func html(code: String, isDark: Bool, fullScreen: Bool) -> String {
            let encoded = Data(code.utf8).base64EncodedString()
            let themeName = isDark ? "dark" : "default"
            let textColor = isDark ? "#E6EAF2" : "#1B202B"
            let viewport = fullScreen
                ? "width=device-width, initial-scale=1.0, minimum-scale=0.4, maximum-scale=6.0, user-scalable=yes"
                : "width=device-width, initial-scale=1.0, minimum-scale=0.6, maximum-scale=3.5, user-scalable=yes"
            return """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="\(viewport)">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
              <style>
                html, body {
                  margin: 0; padding: 0;
                  background: transparent;
                  color: \(textColor);
                  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                  overflow: auto;
                }
                #wrap {
                  padding: 14px;
                  display: flex;
                  justify-content: center;
                  align-items: flex-start;
                  min-width: min-content;
                }
                #wrap svg {
                  max-width: 100%;
                  height: auto;
                }
              </style>
            </head>
            <body>
              <div id="wrap"></div>
              <script>
                (async function() {
                  function send(payload) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mermaidBridge) {
                      window.webkit.messageHandlers.mermaidBridge.postMessage(payload);
                    }
                  }
                  try {
                    if (!window.mermaid) { send({ error: true }); return; }
                    const bytes = Uint8Array.from(atob("\(encoded)"), c => c.charCodeAt(0));
                    const src = new TextDecoder("utf-8").decode(bytes).trim();
                    if (!src) { send({ height: 120 }); return; }
                    window.mermaid.initialize({
                      startOnLoad: false,
                      securityLevel: "antiscript",
                      theme: "\(themeName)",
                      flowchart: { htmlLabels: true, curve: "basis" }
                    });
                    const out = await window.mermaid.render("mDiagram", src);
                    const wrap = document.getElementById("wrap");
                    wrap.innerHTML = out.svg;
                    requestAnimationFrame(() => {
                      const h = Math.ceil(wrap.getBoundingClientRect().height + 8);
                      send({ height: Math.max(h, 140) });
                    });
                  } catch (e) {
                    send({ error: true });
                  }
                })();
              </script>
            </body>
            </html>
            """
        }
    }
}
