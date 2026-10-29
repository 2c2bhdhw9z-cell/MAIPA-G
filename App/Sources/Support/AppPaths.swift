import Foundation

/// Where MAIPA-G keeps things on the phone.
struct AppPaths: Sendable {
    /// Application Support/MAIPA-G: kept until the app is deleted.
    let support: URL
    /// The folder mirrored to the private MAIPA-G-data repo: chats and settings.
    let data: URL
    /// What the last save to MAIPA-G-data agreed on.
    let syncState: URL
    /// Caches/MAIPA-G: things that can be downloaded again, which iOS may clear when space is low.
    let caches: URL
    /// Local copies of repos, for searching.
    let repoCopies: URL
    /// OpenRouter's list of AIs.
    let modelCatalogue: URL
    /// Attachments mirrored through MAIPA-G-data.
    let attachments: URL
    /// Generated/downloaded media mirrored through MAIPA-G-data.
    let media: URL

    static func make() -> AppPaths {
        let manager = FileManager.default
        let supportRoot = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cachesRoot = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = supportRoot.appendingPathComponent("MAIPA-G", isDirectory: true)
        let caches = cachesRoot.appendingPathComponent("MAIPA-G", isDirectory: true)
        let paths = AppPaths(
            support: support,
            data: support.appendingPathComponent("data", isDirectory: true),
            syncState: support.appendingPathComponent("sync-state.json"),
            caches: caches,
            repoCopies: caches.appendingPathComponent("RepoCopies", isDirectory: true),
            modelCatalogue: caches.appendingPathComponent("models.json"),
            attachments: support.appendingPathComponent("data/attachments", isDirectory: true),
            media: support.appendingPathComponent("data/media", isDirectory: true)
        )
        for folder in [paths.support, paths.data, paths.caches, paths.repoCopies, paths.attachments, paths.media] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return paths
    }
}
