import Foundation
import Testing
@testable import AgentCore

@Suite("Connector OAuth address safety")
struct OAuthURLPolicyTests {
    @Test(arguments: [
        "http://auth.example.com",
        "https://user:password@auth.example.com",
        "https://auth.example.com/path#fragment",
        "https://localhost/token",
        "https://127.0.0.1/token",
        "https://10.0.0.1/token",
        "https://169.254.169.254/token",
        "https://192.168.1.2/token",
        "https://[::1]/token",
    ])
    func rejectsUnsafeAddresses(value: String) {
        #expect(throws: MCPAuthorizationError.self) {
            _ = try OAuthURLPolicy.validate(URL(string: value)!)
        }
    }

    @Test func preservesIssuerPortAndPathInMetadataAddress() throws {
        let result = try OAuthURLPolicy.authorizationMetadataURL(for: URL(string: "https://auth.example.com:8443/tenant")!)
        #expect(result.absoluteString == "https://auth.example.com:8443/.well-known/oauth-authorization-server/tenant")
    }

    @Test func originChecksRejectDeceptiveAndCrossOriginHosts() throws {
        let trusted = URL(string: "https://auth.example.com")!
        #expect(throws: MCPAuthorizationError.self) {
            _ = try OAuthURLPolicy.requireSameOrigin(URL(string: "https://auth.example.com.evil.test/token")!, as: trusted)
        }
        #expect(throws: MCPAuthorizationError.self) {
            _ = try OAuthURLPolicy.requireSameOrigin(URL(string: "https://other.example.com/token")!, as: trusted)
        }
        #expect(try OAuthURLPolicy.requireSameOrigin(URL(string: "https://auth.example.com/token")!, as: trusted).path == "/token")
    }

    @Test func callbackMustMatchTheExactAppRoute() {
        let expected = MCPOAuthClient.appCallbackURL
        #expect(OAuthURLPolicy.isExpectedCallback(URL(string: "maipag://mcp?code=ok&state=s")!, expected: expected))
        #expect(!OAuthURLPolicy.isExpectedCallback(URL(string: "maipag://other?code=ok")!, expected: expected))
        #expect(!OAuthURLPolicy.isExpectedCallback(URL(string: "maipag://mcp/path?code=ok")!, expected: expected))
        #expect(!OAuthURLPolicy.isExpectedCallback(URL(string: "maipag://mcp?code=ok#fragment")!, expected: expected))
    }

    @Test func discoveryRejectsCrossOriginTokenEndpointWithoutCallingIt() async {
        final class HostileTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                if request.url.path.contains("oauth-protected-resource") {
                    return HTTPResponse(status: 200, body: Data(#"{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"]}"#.utf8))
                }
                return HTTPResponse(status: 200, body: Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://evil.example.net/token"}"#.utf8))
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() })
            }
        }

        await #expect(throws: MCPAuthorizationError.self) {
            _ = try await MCPOAuthClient(transport: HostileTransport()).discover(endpoint: URL(string: "https://mcp.example.com/mcp")!)
        }
    }
}
