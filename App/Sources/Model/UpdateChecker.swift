import AgentCore
import Foundation
import Observation

/// Notices when a newer MAIPA-G build has been published, for Settings to say so.
@MainActor
@Observable
final class UpdateChecker {
    static let repo = RepoRef(owner: "2c2bhdhw9z-cell", name: "MAIPA-G")
    /// Always the newest build's .ipa.
    static let latestDownload = URL(string: "https://github.com/2c2bhdhw9z-cell/MAIPA-G/releases/latest/download/MAIPA-G.ipa")!

    private(set) var newer: GitHubRelease?
    private(set) var isChecking = false
    private(set) var statusMessage: String?
    @ObservationIgnored private var lastCheck: Date?

    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    var newerBuildNumber: Int? { newer?.buildNumber }

    /// The numbered .ipa of the newer build, so it's clear in Files which one it is.
    var downloadURL: URL {
        if let asset = newer?.assets.first(where: { $0.name.hasPrefix("MAIPA-G-") && $0.name.hasSuffix(".ipa") }), let url = URL(string: asset.downloadURL) {
            return url
        }
        return Self.latestDownload
    }

    /// Checks at most once an hour unless `force`.
    func check(using client: GitHubClient, force: Bool = false) async {
        if isChecking { return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        lastCheck = Date()
        if force {
            isChecking = true
            statusMessage = nil
        }
        defer { isChecking = false }
        do {
            guard let release = try await client.latestRelease(Self.repo), let number = release.buildNumber else {
                if force {
                    statusMessage = "You’re on the newest build (build \(currentBuild))."
                    Haptics.selection()
                }
                return
            }
            if number > currentBuild {
                newer = release
                if force {
                    statusMessage = "Build \(number) is out and ready to install."
                    Haptics.tap()
                }
            } else {
                newer = nil
                if force {
                    statusMessage = "You’re on the newest build (build \(currentBuild))."
                    Haptics.selection()
                }
            }
        } catch {
            if force {
                statusMessage = ErrorExplainer.explain(error).cause
            }
        }
    }
}
