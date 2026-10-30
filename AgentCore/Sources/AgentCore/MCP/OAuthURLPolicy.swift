import Foundation

/// Validates every address used during connector OAuth before MAIPA-G opens it or sends a
/// credential. The policy is deliberately strict: discovery may name a separate public issuer,
/// but every endpoint published by that issuer must stay on the issuer's origin.
public enum OAuthURLPolicy {
    public static func validate(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              !isLocalOrPrivate(host)
        else { throw MCPAuthorizationError.insecureURL }
        if let port = components.port, !(1...65_535).contains(port) {
            throw MCPAuthorizationError.insecureURL
        }
        return url
    }

    public static func requireSameOrigin(_ candidate: URL, as trusted: URL) throws -> URL {
        let candidate = try validate(candidate)
        let trusted = try validate(trusted)
        guard origin(candidate) == origin(trusted) else {
            throw MCPAuthorizationError.discovery("A connector sign-in address pointed to an unexpected site.")
        }
        return candidate
    }

    public static func authorizationMetadataURL(for issuer: URL) throws -> URL {
        let issuer = try validate(issuer)
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
            throw MCPAuthorizationError.insecureURL
        }
        let issuerPath = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
        components.percentEncodedPath = "/.well-known/oauth-authorization-server" + issuerPath
        components.query = nil
        components.fragment = nil
        guard let result = components.url else { throw MCPAuthorizationError.insecureURL }
        return result
    }

    public static func protectedResourceMetadataURLs(for endpoint: URL) throws -> [URL] {
        let endpoint = try validate(endpoint)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MCPAuthorizationError.insecureURL
        }
        let resourcePath = components.percentEncodedPath
        components.query = nil
        components.fragment = nil
        var values: [URL] = []
        if !resourcePath.isEmpty, resourcePath != "/" {
            components.percentEncodedPath = "/.well-known/oauth-protected-resource" + resourcePath
            if let value = components.url { values.append(value) }
        }
        components.percentEncodedPath = "/.well-known/oauth-protected-resource"
        if let value = components.url, !values.contains(value) { values.append(value) }
        return values
    }

    public static func isExpectedCallback(_ callback: URL, expected: URL) -> Bool {
        guard callback.scheme?.lowercased() == expected.scheme?.lowercased(),
              callback.host?.lowercased() == expected.host?.lowercased(),
              callback.port == expected.port,
              callback.path == expected.path,
              callback.user == nil, callback.password == nil,
              callback.fragment == nil
        else { return false }
        return true
    }

    public static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : -1)
        return "\(scheme)://\(host):\(port)"
    }

    private static func isLocalOrPrivate(_ host: String) -> Bool {
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if unbracketed == "localhost" || unbracketed.hasSuffix(".localhost") ||
            unbracketed.hasSuffix(".local") || unbracketed.hasSuffix(".internal") {
            return true
        }
        // IPv6 literals are rejected. Public connector issuers should use a stable DNS name;
        // rejecting literals also covers loopback, link-local and unique-local IPv6 ranges.
        if unbracketed.contains(":") { return true }
        let parts = unbracketed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4 else { return true }
        let a = octets[0], b = octets[1], c = octets[2]
        return a == 0 || a == 10 || a == 127 || a >= 224 ||
            (a == 100 && (64...127).contains(b)) ||
            (a == 169 && b == 254) ||
            (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) ||
            (a == 198 && (b == 18 || b == 19)) ||
            (a == 192 && b == 0 && (c == 0 || c == 2)) ||
            (a == 198 && b == 51 && c == 100) ||
            (a == 203 && b == 0 && c == 113)
    }
}
