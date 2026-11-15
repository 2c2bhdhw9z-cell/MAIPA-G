import Foundation
import Testing
@testable import AgentCore

/// GitHub access on the computer renews itself (owner, 15 November 2026: "GitHub access shouldn't
/// just be able to expire, doesn't for you"). The Korg reply got "Bad credentials" about an hour in.
@Suite("GitHub access on the computer renews itself")
struct GitHubTokenRenewalTests {
    /// A throwaway 2048-bit key in GitHub's own format (PKCS#1), made for this test only.
    /// The header lines are put together at run time so the file doesn't look like a real key.
    static let testKeyPEM = ["-----BEGIN " + "RSA PRIVATE KEY-----"] + testKeyBody + ["-----END " + "RSA PRIVATE KEY-----"]
    static var testKey: String { testKeyPEM.joined(separator: "\n") }
    static let testKeyBody = [
        "MIIEogIBAAKCAQEAtKcLAaXtaBC9EFdVnFQjEg20oV6Y5jilFZl8BNZwgBelSmui",
        "WTcbtckOykXDDoRSBWOT7RZ+jMxxiSWp2qXPg3CBFpjcTe130vU/IRAsVtbTVaxp",
        "/XNEoyE8TSMtcoU0bwsjR3STernSmuX9V5RJ5mNYuYP3OyMLQVVUHOkay2kihlM1",
        "oErZ2BtG6YJQZzNNA22SaC4/Xvucyg/zsGAknQq9jfWnkkz7ud2WEGju0dgW67eG",
        "lWCKo7NRhiM3yrbmPhY1YlXPrFaj9hTWXH4V81WVtmafNLYyhyxsHKn9qZF4qC7/",
        "GV4/5KwSBXnF/ADSKWAJJrJgpwUWx5veiNuCfQIDAQABAoIBABMRxwGniEYB7lM5",
        "RNo5r3IKbFTUbYNv201KZGMGV93NoS8X6Y1NWel4jc0gTBTONvJGrqjKRRWLxzhY",
        "93MTKbKQP7Ao9qhrNsjYBo/w6x1HlAtpJc8RSd+GdJ0X54Y9NWm7XT//uEmuL+MW",
        "AAYsqxhcyFLc8U4WxutgnH5oxOFPy91Dp+IxMVG09Ik1ZbyHB1biyByqTlqIhwzg",
        "dD30aD+o3P79XNqfU1dITZhligE+ylrI7emy7PFZugOjJGDOOTkeQ/HJYUt+K3tk",
        "edvIFOjlPX0Hr0ipkSapLf9dnvzLj2jV/Dk1soTUUCxn+xPURd30ltRm52vk3vYO",
        "4Y/DagECgYEA+m40JYM+nH9fkl1NZts8+bZR6ehDRkJeYgX3mCFsP23EQhKRvus0",
        "J220n0APJUSIaxvYvBlUDDvv9oZKI2t48iHnvKBh3UMtuSXkeAZyGzcCliwGvzVx",
        "jOj8oNcn8zRLz2ZTGb7bwE+80KLFwVGkelbbo9qmfQEeXn/fql8JOkECgYEAuKuR",
        "EdJCEBfj9Sb2tYVF5BFNudakVHucNXWWzI5pHooxN57T5DZyh9KmKAEnvedHGc5q",
        "pMpR9xrqh7mR4a1fxmV4XkKbZCGvpy84F96F7AuoPkp16xX1KtPB8Gd+GvJnCDJ8",
        "wQtlbCv1No2ye64oxPp3MWEmK1WECHj1IaMWYT0CgYANAOnuRLlckPSaegPJ4npx",
        "EPmB5tCPdmTGPD8WBC5FwOJe9+3fdwEXRwgI+N+QdNWMkj6Xzczicb5NE74Hxs3Z",
        "7M7GqaFLRvC523DYlqUYKqwUtiaHiTPjODnd9C4b38xL8alA/fsVKk7ImpsgJagf",
        "viDbij/437T+/S7U/uhQwQKBgANb23+fe2Qfix3iX4pdqi/DwM4ogUSoGuc+BEgk",
        "LvVHPi3szZ3Q/7RIuIzxuG9TzY9Cmd31cBg2fR2K2oRoSt2o6s+MFpdzpWY9DaAh",
        "g/4PGDhJ0ms8MwFcaKKev0RuNEGJ6Yr5UhbtlcAwQ5bMTCGJDLHxOmh/Xa9pw8ug",
        "079hAoGAYMPKvhWoBNN+9ogddQVEYM1aDIRcHDTPwxYxb8lVrT/mMZhcUMcZWVed",
        "4FT6mocTxOP+fHyLZv8CcN4QXra8bckLUBcbQWGTftcXrJsg2hfDVRhwK4MZtrEw",
        "qnMZpoFUStnLiq9UHcKVDDrlXYtJplc86r3PAZlAqif7UjBLlHg=",
    ]
    /// Its RS256 signature of "header.payload", made and checked with Node's crypto. RSASSA-PKCS1-v1_5
    /// is deterministic, so the phone's signer and the computer's must give exactly this.
    static let expectedSignature = "hEjHTY8QhCEHFYSbxY5xki49Z7sw5koz80pRzLXK/iQ0iMMMDqXEjPCRopTBX+uu1tQpYIWB9BTO0dkdvhLlnOUO4uTjJJEjIKnoNHw1zZZXgspK9net2wxX3/RZkI65R91FMvZ6k6Hi3BOXY6i880DnBE4GPjwsTsMlw1swFnf+C58es4CgwdOKITsHz/+hwMDSODQToNY53oT+VL0svgaeTn3eAXwBGU5cY9T3tQsvGpwgLDpSLNmK/rxhS+eOiaooW5WV9DztAjLteRaWCRQshluGx20IdfCcHamyc220e4O6lHqrx4rsvoBVZ71R02Xrv/YQKo/tuHtZGHtNXw=="

    @Test("This system's signer makes the exact RS256 signature GitHub checks")
    func signerMatchesAKnownSignature() throws {
        let signer = try RS256Signers.make(pem: Self.testKey)
        #expect(try signer.sign(Data("header.payload".utf8)).base64EncodedString() == Self.expectedSignature)
    }

    final class Recorder: HTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [HTTPRequest] = []
        var minted = 0
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { requests.append(request) }
            if request.url.path.hasSuffix("/access_tokens") {
                let n = lock.withLock { minted += 1; return minted }
                let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
                return HTTPResponse(status: 201, headers: ["content-type": "application/json"], body: Data(#"{"token":"ghs_minted_\#(n)","expires_at":"\#(expires)"}"#.utf8))
            }
            // GitHub refuses the old handed-over token.
            if request.headers["Authorization"] == "Bearer ghs_old" { return HTTPResponse(status: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8)) }
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"{"ok":true}"#.utf8))
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse { HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() }) }
    }

    @Test("The minter asks GitHub as the app, narrowed when asked to one repo's contents")
    func minterAsksAsTheApp() async throws {
        let recorder = Recorder()
        let minter = GitHubAppTokenMinter(clientID: "Iv1.test", installationID: 42, signer: try RS256Signers.make(pem: Self.testKey), transport: recorder)
        let narrow = try await minter.mint(repositories: ["MAIPA-G-data"], permissions: ["contents": "write"])
        #expect(narrow.token == "ghs_minted_1" && narrow.expiresAt > Date().addingTimeInterval(3000))
        let sent = try #require(recorder.requests.last)
        #expect(sent.method == "POST" && sent.url.path == "/app/installations/42/access_tokens")
        let jwt = try #require(sent.headers["Authorization"]?.replacingOccurrences(of: "Bearer ", with: ""))
        #expect(jwt.split(separator: ".").count == 3)
        let body = try #require(sent.body.flatMap(JSONValue.parse))
        #expect(body["repositories"]?.arrayValue?.first?.stringValue == "MAIPA-G-data")
        #expect(body["permissions"]?["contents"]?.stringValue == "write")
    }

    @Test("A refused token is renewed at once, with no wait for the phone, and the request goes through")
    func refusedTokenIsRenewed() async throws {
        let recorder = Recorder()
        let minter = GitHubAppTokenMinter(clientID: "Iv1.test", installationID: 42, signer: try RS256Signers.make(pem: Self.testKey), transport: recorder)
        let tokens = HandedOverTokens(token: "ghs_old", refreshFile: nil, waitForFresh: 600, renew: { try await minter.mint() })
        let github = GitHubClient(transport: recorder, tokens: tokens)
        let started = Date()
        let response = try await github.send("GET", "/repos/octo/korg/pulls/2")
        #expect(response.status == 200)
        #expect(Date().timeIntervalSince(started) < 5, "no 10-minute wait for the phone")
        #expect(try await tokens.installationToken() == "ghs_minted_1")
    }

    @Test("A token near its end is renewed before GitHub refuses it, once for everyone asking at the same time")
    func nearExpiryIsRenewedOnce() async throws {
        let recorder = Recorder()
        let minter = GitHubAppTokenMinter(clientID: "Iv1.test", installationID: 42, signer: try RS256Signers.make(pem: Self.testKey), transport: recorder)
        let tokens = HandedOverTokens(token: "ghs_handed", refreshFile: nil, renew: { try await minter.mint() }, expiresAt: Date().addingTimeInterval(5 * 60))
        async let a = tokens.installationToken()
        async let b = tokens.installationToken()
        let (first, second) = try await (a, b)
        #expect(first == "ghs_minted_1" && second == "ghs_minted_1")
        #expect(recorder.minted == 1)
        // A fresh token isn't renewed again.
        #expect(try await tokens.installationToken() == "ghs_minted_1" && recorder.minted == 1)
        // Without a key, a token near its end is used as it is (the phone renews it).
        let phoneOnly = HandedOverTokens(token: "ghs_handed", refreshFile: nil, expiresAt: Date().addingTimeInterval(60))
        #expect(try await phoneOnly.installationToken() == "ghs_handed")
    }

    @Test("The key is kept out of logs, and keys from older app builds still read")
    func keyIsRedactedAndOldSecretsDecode() throws {
        let secrets = VMSecrets(openRouterKey: nil, githubToken: "ghs_token_value", githubApp: VMGitHubApp(clientID: "Iv1.test", installationID: 42, privateKeyPEM: Self.testKey))
        let line = Self.testKeyBody[3]
        let logger = RedactingLogger(secrets: secrets.allValues)
        #expect(!logger.redact("leaked: \(line)").contains(line))
        let old = try JSONCoding.decoder().decode(VMSecrets.self, from: Data(#"{"providers":[],"githubToken":"x","connectors":[],"connectorSecrets":{}}"#.utf8))
        #expect(old.githubApp == nil)
    }
}

@Suite("Real spend is told apart across app restarts")
struct BalanceOverlapPersistenceTests {
    /// The Continuum reply (00:30-03:49) showed $38.29 because the Korg reply on the same provider
    /// had been forgotten when the app restarted in between.
    @Test("A turn still running when the app restarts is remembered, so an overlapping turn is marked shared")
    func survivesARestart() throws {
        var tracker = BalanceOverlapTracker()
        let korg = UUID(), continuum = UUID()
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        tracker.begin(korg, provider: "oneprovider", at: start)
        let saved = try JSONEncoder().encode(tracker)
        var relaunched = try JSONDecoder().decode(BalanceOverlapTracker.self, from: saved)
        relaunched.begin(continuum, provider: "oneprovider", at: start.addingTimeInterval(3600))
        let shared = relaunched.end(continuum, at: start.addingTimeInterval(7200))
        #expect(shared)
        #expect(relaunched.isShared(korg))
    }

    @Test("A turn left marked running for a day stops counting, so it can't mark every later turn shared")
    func staleRunningTurnsGo() {
        var tracker = BalanceOverlapTracker()
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        tracker.begin(UUID(), provider: "oneprovider", at: start)
        let later = UUID()
        tracker.begin(later, provider: "oneprovider", at: start.addingTimeInterval(BalanceOverlapTracker.staleAfter + 60))
        let shared = tracker.end(later, at: start.addingTimeInterval(BalanceOverlapTracker.staleAfter + 600))
        #expect(!shared)
    }
}
