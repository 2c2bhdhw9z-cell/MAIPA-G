import Foundation
#if canImport(Security)
import Security
#endif

/// Signs bytes with RSASSA-PKCS1-v1_5 and SHA-256, the "RS256" that GitHub app tokens use.
public protocol RS256Signer: Sendable {
    func sign(_ message: Data) throws -> Data
}

public enum GitHubAppJWT {
    /// A short-lived token proving "I am this GitHub app". GitHub allows at most ten minutes;
    /// the issue time is set a minute back to allow for a phone clock that runs fast.
    public static func make(clientID: String, signer: any RS256Signer, now: Date = Date()) throws -> String {
        let header: JSONValue = ["alg": "RS256", "typ": "JWT"]
        let issuedAt = Int(now.timeIntervalSince1970) - 60
        let payload: JSONValue = ["iat": .number(Double(issuedAt)), "exp": .number(Double(issuedAt + 9 * 60)), "iss": .string(clientID)]
        let signingInput = Base64URL.encode(Data(header.jsonString().utf8)) + "." + Base64URL.encode(Data(payload.jsonString().utf8))
        let signature = try signer.sign(Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature)
    }
}

public enum PEM {
    public enum Failure: Error, Sendable { case notPEM, unsupportedKey }

    /// The DER bytes inside a PEM block, and the block's label ("RSA PRIVATE KEY", "PRIVATE KEY").
    public static func decode(_ pem: String) throws -> (label: String, der: Data) {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") }),
              let end = lines.lastIndex(where: { $0.hasPrefix("-----END ") }), begin < end
        else { throw Failure.notPEM }
        let label = lines[begin].replacingOccurrences(of: "-----BEGIN ", with: "").replacingOccurrences(of: "-----", with: "")
        let body = lines[(begin + 1)..<end].joined()
        guard let der = Data(base64Encoded: body) else { throw Failure.notPEM }
        return (label, der)
    }

    /// An RSA private key as PKCS#1 DER, whichever of the two common PEM forms it came in.
    /// GitHub hands out PKCS#1 ("BEGIN RSA PRIVATE KEY"); PKCS#8 ("BEGIN PRIVATE KEY") wraps the
    /// same bytes in an algorithm header, which is peeled off here.
    public static func rsaPrivateKeyPKCS1(_ pem: String) throws -> Data {
        let (label, der) = try decode(pem)
        switch label {
        case "RSA PRIVATE KEY":
            return der
        case "PRIVATE KEY":
            // PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
            var reader = DERReader(der)
            var info = try reader.readElement(tag: 0x30).contents
            _ = try info.readElement(tag: 0x02)
            _ = try info.readElement(tag: 0x30)
            return try info.readElement(tag: 0x04).contents.remaining
        default:
            throw Failure.unsupportedKey
        }
    }
}

/// Just enough DER to unwrap a PKCS#8 key.
struct DERReader {
    enum Failure: Error { case malformed }
    private let bytes: [UInt8]
    private var position: Int

    init(_ data: Data) {
        bytes = Array(data)
        position = 0
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
        position = 0
    }

    var remaining: Data { Data(bytes[position...]) }

    mutating func readElement(tag expected: UInt8) throws -> (tag: UInt8, contents: DERReader) {
        guard position < bytes.count else { throw Failure.malformed }
        let tag = bytes[position]
        guard tag == expected else { throw Failure.malformed }
        position += 1
        guard position < bytes.count else { throw Failure.malformed }
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, position + count <= bytes.count else { throw Failure.malformed }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[position])
                position += 1
            }
        }
        guard position + length <= bytes.count else { throw Failure.malformed }
        let contents = Array(bytes[position..<(position + length)])
        position += length
        return (tag, DERReader(bytes: contents))
    }
}

#if canImport(Security)
/// RS256 with the phone's own Security framework. The key is created from the PEM each time the
/// app starts and is never written anywhere except the Keychain item it came from.
public struct SecurityRS256Signer: RS256Signer, @unchecked Sendable {
    public enum Failure: Error, Sendable { case badKey(String), signingFailed(String) }
    private let key: SecKey

    public init(pem: String) throws {
        let der = try PEM.rsaPrivateKeyPKCS1(pem)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw Failure.badKey(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        self.key = key
    }

    public func sign(_ message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
            throw Failure.signingFailed(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        return signature as Data
    }

    /// Checks a signature with the matching public key. Used by the tests and by the app's
    /// "is the saved key still good" check.
    public func verify(_ signature: Data, for message: Data) -> Bool {
        guard let publicKey = SecKeyCopyPublicKey(key) else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }
}
#endif

/// Issues GitHub tokens for one connected account, renewing them before they run out.
///
/// Installation tokens (MAIPA-G acting as its own bot) last an hour and are made on the phone by
/// signing a JWT with the app's private key. User tokens last eight hours and are renewed with
/// their refresh token, which lasts six months; renewed ones are handed to `onUserTokenChange`
/// so the app can save them.
public actor GitHubAppSession: GitHubTokenProvider {
    public enum Failure: Error, Sendable, Equatable {
        /// The user token can no longer be renewed: the user has to connect GitHub again.
        case userSignInExpired
        case noUserToken
    }

    public let credentials: GitHubAppCredentials
    public let installationID: Int
    private let signer: any RS256Signer
    private let transport: any HTTPTransport
    private let onUserTokenChange: @Sendable (GitHubUserToken) async -> Void
    private var cachedInstallationToken: (token: String, expiresAt: Date)?
    private var installationRefresh: Task<(token: String, expiresAt: Date), Error>?
    private var currentUserToken: GitHubUserToken?
    private var userRefresh: Task<GitHubUserToken, Error>?

    public init(
        credentials: GitHubAppCredentials,
        installationID: Int,
        userToken: GitHubUserToken?,
        signer: any RS256Signer,
        transport: any HTTPTransport,
        onUserTokenChange: @escaping @Sendable (GitHubUserToken) async -> Void
    ) {
        self.credentials = credentials
        self.installationID = installationID
        self.currentUserToken = userToken
        self.signer = signer
        self.transport = transport
        self.onUserTokenChange = onUserTokenChange
    }

    public func installationToken() async throws -> String {
        if let cached = cachedInstallationToken, cached.expiresAt.timeIntervalSinceNow > 5 * 60 {
            return cached.token
        }
        if let running = installationRefresh { return try await running.value.token }
        let credentials = credentials, installationID = installationID, signer = signer, transport = transport
        let task = Task<(token: String, expiresAt: Date), Error> {
            let jwt = try GitHubAppJWT.make(clientID: credentials.clientID, signer: signer)
            let client = GitHubClient(transport: transport, tokens: nil)
            let response = try await client.send("POST", "/app/installations/\(installationID)/access_tokens", auth: .bearer(jwt))
            guard let json = JSONValue.parse(response.body), let token = json["token"]?.stringValue else {
                throw GitHubAPIError(status: response.status, message: "GitHub sent no installation token")
            }
            let expiresAt = json["expires_at"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date().addingTimeInterval(55 * 60)
            return (token, expiresAt)
        }
        installationRefresh = task
        defer { installationRefresh = nil }
        let fresh = try await task.value
        cachedInstallationToken = fresh
        return fresh.token
    }

    public func userToken() async throws -> String {
        guard let token = currentUserToken else { throw Failure.noUserToken }
        if token.isFresh() { return token.accessToken }
        if let running = userRefresh { return try await running.value.accessToken }
        guard token.canRefresh(), let refreshToken = token.refreshToken else { throw Failure.userSignInExpired }
        let credentials = credentials, transport = transport
        let task = Task<GitHubUserToken, Error> {
            try await GitHubConnect.requestUserToken(
                parameters: [
                    "client_id": credentials.clientID,
                    "client_secret": credentials.clientSecret,
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                ],
                transport: transport
            )
        }
        userRefresh = task
        defer { userRefresh = nil }
        do {
            let fresh = try await task.value
            currentUserToken = fresh
            await onUserTokenChange(fresh)
            return fresh.accessToken
        } catch let error as GitHubConnect.Failure {
            if case .oauth(let code, _) = error, code == "bad_refresh_token" { throw Failure.userSignInExpired }
            throw error
        }
    }

    /// Drops the cached installation token, for after GitHub has refused it.
    public func forgetInstallationToken() {
        cachedInstallationToken = nil
    }
}

/// The steps of connecting GitHub: making the user's own MAIPA-G app, then letting it in.
public enum GitHubConnect {
    public enum Failure: Error, Sendable, Equatable {
        case oauth(code: String, message: String)
        case unexpectedReply(String)
        case notInstalled
    }

    /// MAIPA-G's GitHub Pages site. It holds the app's recipe (the manifest) and the pages that
    /// pass GitHub's and OpenRouter's answers back into the app.
    public static let pagesBase = URL(string: "https://2c2bhdhw9z-cell.github.io/MAIPA-G/")!
    public static let callbackScheme = "maipag"

    /// The page that sends the recipe to GitHub. GitHub then asks the user to confirm the name.
    public static func manifestPageURL(state: String, appName: String) -> URL {
        var components = URLComponents(url: pagesBase.appendingPathComponent("github/new/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "name", value: appName)]
        return components.url!
    }

    /// Where GitHub sends the user back after the app is made. Must match the page's manifest.
    public static var createdRedirectURL: URL { pagesBase.appendingPathComponent("github/created/") }
    /// Where GitHub sends the user back after installing and authorizing the app.
    public static var authorizedRedirectURL: URL { pagesBase.appendingPathComponent("github/authorized/") }

    /// Swaps the one-hour code from the manifest flow for the new app's id, keys and secrets.
    public static func convertManifest(code: String, transport: any HTTPTransport) async throws -> GitHubAppCredentials {
        let client = GitHubClient(transport: transport, tokens: nil)
        let response = try await client.send("POST", "/app-manifests/\(GitHubClient.escape(code))/conversions", auth: .none)
        guard let json = JSONValue.parse(response.body),
              let id = json["id"]?.intValue,
              let slug = json["slug"]?.stringValue,
              let clientID = json["client_id"]?.stringValue,
              let clientSecret = json["client_secret"]?.stringValue,
              let pem = json["pem"]?.stringValue
        else { throw Failure.unexpectedReply("GitHub's reply about the new app was missing parts") }
        return GitHubAppCredentials(
            appID: id,
            slug: slug,
            name: json["name"]?.stringValue ?? slug,
            clientID: clientID,
            clientSecret: clientSecret,
            privateKeyPEM: pem,
            ownerLogin: json["owner"]?["login"]?.stringValue ?? "",
            htmlURL: json["html_url"]?.stringValue ?? "https://github.com/apps/\(slug)"
        )
    }

    /// The page where the user installs their new app on their account.
    public static func installURL(slug: String) -> URL {
        URL(string: "https://github.com/apps/\(GitHubClient.escape(slug))/installations/new")!
    }

    /// The page where the user lets their MAIPA-G app act for them. GitHub sends them back to the
    /// app's first callback address (the "authorized" bounce page) with a code.
    public static func authorizeURL(clientID: String, state: String, pkce: PKCE) -> URL {
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Swaps the code GitHub sends after the user authorizes the app for a user token.
    /// `verifier` is the PKCE secret when the sign-in was started with `authorizeURL`.
    public static func exchangeAuthorizationCode(_ code: String, credentials: GitHubAppCredentials, verifier: String? = nil, transport: any HTTPTransport) async throws -> GitHubUserToken {
        var parameters = [
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "code": code,
        ]
        if let verifier { parameters["code_verifier"] = verifier }
        return try await requestUserToken(parameters: parameters, transport: transport)
    }

    /// Whether the user's MAIPA-G app still exists on GitHub and its saved key still works.
    /// Only a clear answer from GitHub counts as no: the app is gone, or the key was deleted.
    /// Network trouble, or a phone clock so far off that GitHub refuses the token's times, counts as
    /// yes, so MAIPA-G never forgets a working connection by mistake.
    public static func appStillWorks(credentials: GitHubAppCredentials, signer: any RS256Signer, transport: any HTTPTransport) async -> Bool {
        guard let jwt = try? GitHubAppJWT.make(clientID: credentials.clientID, signer: signer) else { return false }
        let client = GitHubClient(transport: transport, tokens: nil)
        do {
            let response = try await client.send("GET", "/app", auth: .bearer(jwt), allow: [401, 404])
            if response.isSuccess { return true }
            let message = (JSONValue.parse(response.body)?["message"]?.stringValue ?? "").lowercased()
            return !(response.status == 404 || message.contains("not found") || message.contains("could not be decoded"))
        } catch {
            return true
        }
    }

    /// Takes MAIPA-G's app off the user's account (the app itself stays, for connecting again).
    public static func uninstall(installationID: Int, credentials: GitHubAppCredentials, signer: any RS256Signer, transport: any HTTPTransport) async throws {
        let jwt = try GitHubAppJWT.make(clientID: credentials.clientID, signer: signer)
        let client = GitHubClient(transport: transport, tokens: nil)
        _ = try await client.send("DELETE", "/app/installations/\(installationID)", auth: .bearer(jwt), allow: [404])
    }

    /// A page of MAIPA-G's Pages site, such as "openrouter/".
    public static func page(_ path: String) -> URL {
        URL(string: path, relativeTo: pagesBase)!.absoluteURL
    }

    static func requestUserToken(parameters: [String: String], transport: any HTTPTransport) async throws -> GitHubUserToken {
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let form = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let request = HTTPRequest(
            method: "POST",
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "MAIPA-G"],
            body: Data(form.utf8),
            idleTimeout: 30
        )
        let response = try await transport.send(request)
        guard let json = JSONValue.parse(response.body) else {
            throw Failure.unexpectedReply("GitHub's sign-in reply was not readable (HTTP \(response.status))")
        }
        // GitHub reports OAuth errors with status 200 and an "error" field.
        if let error = json["error"]?.stringValue {
            throw Failure.oauth(code: error, message: json["error_description"]?.stringValue ?? error)
        }
        guard let accessToken = json["access_token"]?.stringValue else {
            throw Failure.unexpectedReply("GitHub's sign-in reply had no token")
        }
        let now = Date()
        return GitHubUserToken(
            accessToken: accessToken,
            expiresAt: json["expires_in"]?.doubleValue.map { now.addingTimeInterval($0) },
            refreshToken: json["refresh_token"]?.stringValue,
            refreshTokenExpiresAt: json["refresh_token_expires_in"]?.doubleValue.map { now.addingTimeInterval($0) }
        )
    }

    /// Where the app is installed, asked as the app itself. Trusting this rather than the
    /// installation id in a redirect is what GitHub recommends.
    public static func installations(credentials: GitHubAppCredentials, signer: any RS256Signer, transport: any HTTPTransport) async throws -> [GitHubInstallation] {
        let jwt = try GitHubAppJWT.make(clientID: credentials.clientID, signer: signer)
        let client = GitHubClient(transport: transport, tokens: nil)
        return try await client.send("GET", "/app/installations", auth: .bearer(jwt)).decode([GitHubInstallation].self)
    }
}
