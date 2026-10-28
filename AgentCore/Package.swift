// swift-tools-version: 6.0
//
// AgentCore is MAIPA-G's brain: the AI conversation loop, the OpenRouter and GitHub clients, the
// local copies of repos it reads and searches, and the saved-data format. It uses no Apple-only
// framework in its required code paths, so it builds and tests on Linux as well as iOS. The iPhone
// app (App/) is a SwiftUI shell around it, and the cloud runner planned for build 3 will reuse it.
//
// ChatMarkdown turns the AI's Markdown replies into a small block model the app draws natively. It
// sits in this package, rather than in the app, so its behaviour is covered by tests on Linux too.

import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "ChatMarkdown", targets: ["ChatMarkdown"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
        // Hashes (SHA-256 for sign-in codes, SHA-1 for Git object ids). On Apple platforms this is
        // CryptoKit itself; on Linux it is the same API over BoringSSL.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        // zlib, for unpacking the gzip'd tarballs GitHub serves. A C target rather than a system
        // library so it can wrap inflateInit2, which is a macro Swift cannot call directly.
        .target(
            name: "CZlib",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "AgentCore",
            dependencies: ["CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "ChatMarkdown",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        ),
        .testTarget(
            name: "ChatMarkdownTests",
            dependencies: ["ChatMarkdown"]
        ),
    ]
)
