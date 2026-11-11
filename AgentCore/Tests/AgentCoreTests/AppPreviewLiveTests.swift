import Foundation
import Testing
@testable import AgentCore

/// Runs the real preview script with the real tunnel. Off by default (it needs the internet and
/// takes a while); run with MAIPAG_PREVIEW_TESTS=1, MAIPAG_PREVIEW_REPO=<folder with a git repo>.
@Suite("Live preview, for real", .serialized)
struct AppPreviewLiveTests {
    static let enabled = ProcessInfo.processInfo.environment["MAIPAG_PREVIEW_TESTS"] == "1"

    @Test("The preview starts, answers through its public address, and stops", .enabled(if: AppPreviewLiveTests.enabled), .timeLimit(.minutes(15)))
    func previewRunsForReal() async throws {
        let repo = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAIPAG_PREVIEW_REPO"]!)
        let home = repo.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let relative = String(repo.path.dropFirst(home.path.count + 1))
        let control = ComputerControl.local(machine: "test", home: home)
        let tool = AppPreviewTool(control: control, repoHome: relative, prepare: {}, pollEvery: 2, waitUpTo: 800)
        let output = try await tool.run(arguments: ["operation": "start"]) { print("progress:", $0) }
        print(output.forModel)
        let link = try #require(output.livePreview)
        print("LINK", link.webURL, link.expoGoURL ?? "-", link.kind, link.folder)
        var answered = false
        for _ in 0..<20 {
            let page = try await BoundedProcess.run(executable: "/usr/bin/curl", arguments: ["-s", "--max-time", "15", "-H", "Accept: text/html", "-w", "\nmaipa-g-status %{http_code}", link.webURL], directory: home, timeout: 30)
            if page.stdout.contains("maipa-g-status 200") {
                print("WEB", page.stdout.prefix(400))
                answered = true
                break
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        #expect(answered)
        if link.kind == "expo" {
            let manifest = try await BoundedProcess.run(executable: "/usr/bin/curl", arguments: ["-s", "--max-time", "60", "-H", "Accept: application/expo+json,application/json", "-H", "expo-platform: ios", "https://" + link.expoGoURL!.dropFirst("exps://".count)], directory: home, timeout: 90)
            print("MANIFEST", manifest.stdout.prefix(600))
            if let bundle = JSONValue.parse(Data(manifest.stdout.utf8))?["launchAsset"]?["url"]?.stringValue {
                let fetched = try await BoundedProcess.run(executable: "/usr/bin/curl", arguments: ["-s", "-o", "/dev/null", "--max-time", "280", "-w", "%{http_code} %{size_download}", bundle], directory: home, timeout: 300)
                print("BUNDLE", fetched.stdout)
                #expect(fetched.stdout.hasPrefix("200"))
            }
        }
        let stopped = try await tool.run(arguments: ["operation": "stop"]) { _ in }
        print(stopped.forModel)
    }
}

@Suite("Live preview state")
struct AppPreviewStateTests {
    @Test("A ready preview gives the in-app address and, for Expo, the Expo Go one on port 8443")
    func readyStates() {
        guard case .ready(let expo) = AppPreview.parse(state: "ready expo abc-def.trycloudflare.com app", progress: "") else { Issue.record("not ready"); return }
        #expect(expo.webURL == "https://abc-def.trycloudflare.com")
        #expect(expo.expoGoURL == "exps://abc-def.trycloudflare.com:8443")
        #expect(expo.folder == "app")
        guard case .ready(let site) = AppPreview.parse(state: "ready vite abc.trycloudflare.com .", progress: "") else { Issue.record("not ready"); return }
        #expect(site.expoGoURL == nil)
    }

    @Test("Only a Cloudflare quick-tunnel address is trusted; failures and progress read plainly")
    func otherStates() {
        #expect(AppPreview.parse(state: "ready expo evil.example.com .", progress: "") == .failed("The tunnel gave an address MAIPA-G doesn't trust."))
        #expect(AppPreview.parse(state: "ready expo a.trycloudflare.com\"; rm -rf ~ .", progress: "") != AppPreview.parse(state: "ready expo a.trycloudflare.com .", progress: ""))
        #expect(AppPreview.parse(state: "failed: Installing the app's packages failed", progress: "") == .failed("Installing the app's packages failed"))
        #expect(AppPreview.parse(state: "starting", progress: "==> Found a expo app in .\n==> Opening the preview tunnel") == .starting(step: "Opening the preview tunnel"))
        #expect(AppPreview.parse(state: "stopped", progress: "") == .stopped)
        #expect(!AppPreview.isSafeFolder("../outside") && AppPreview.isSafeFolder("apps/mobile") && AppPreview.isSafeFolder("."))
    }

    @Test("The preview script pins the tunnel and checks its checksum before running it")
    func scriptIsPinned() {
        #expect(AppPreview.script.contains("releases/download/2026.10.7/cloudflared-linux-$a"))
        #expect(AppPreview.script.contains("sha256sum -c"))
        #expect(!AppPreview.script.contains("@VERSION@") && !AppPreview.script.contains("@AMD64@") && !AppPreview.script.contains("@PORT@"))
        #expect(!AppPreview.script.contains("latest"))
    }
}
