import Crypto
import Foundation

public enum Base64URL {
    /// Base64 with the URL-safe alphabet and no padding (RFC 4648 §5), as JWTs and PKCE use.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// The id Git gives a file's contents: SHA-1 of "blob <size>\0" followed by the bytes. Used to
    /// tell whether a saved file already matches the copy on GitHub without downloading it.
    public static func gitBlobID(_ contents: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(contents.count)\u{0}".utf8))
        hasher.update(data: contents)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cryptographically random bytes from the system generator.
    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// A random, URL-safe token, for OAuth `state` values and the like.
    public static func randomToken(bytes: Int = 24) -> String {
        Base64URL.encode(randomBytes(bytes))
    }
}

/// Proof Key for Code Exchange (RFC 7636), S256 method.
public struct PKCE: Sendable, Hashable, Codable {
    public let verifier: String
    public let challenge: String

    public init() {
        // 32 random bytes give a 43-character verifier, the minimum length the RFC allows and the
        // length GitHub's documentation asks for.
        let verifier = Base64URL.encode(Hashing.randomBytes(32))
        self.init(verifier: verifier)
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(Hashing.sha256(Data(verifier.utf8)))
    }
}
