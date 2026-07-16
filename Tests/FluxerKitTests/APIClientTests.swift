import Foundation
import Testing
@testable import FluxerKit

@Suite("APIClient request building")
struct APIClientRequestTests {
    @Test func buildsURLAgainstBase() async throws {
        let client = APIClient(baseURL: URL(string: "https://api.example.com/v1")!)
        let request = try await client.makeRequest("GET", Endpoint.me)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/users/@me")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func attachesUserTokenPlain() async throws {
        let client = APIClient()
        await client.setCredential(.user(token: "secret123"))
        let request = try await client.makeRequest("GET", Endpoint.me)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "secret123")
    }

    @Test func attachesBotTokenWithPrefix() async throws {
        let client = APIClient()
        await client.setCredential(.bot(token: "bottoken"))
        let request = try await client.makeRequest("GET", Endpoint.me)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bot bottoken")
    }

    @Test func buildsQueryItems() async throws {
        let client = APIClient()
        let request = try await client.makeRequest(
            "GET",
            Endpoint.messages(Snowflake(77)),
            query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "before", value: "123"),
            ]
        )
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("/channels/77/messages?"))
        #expect(url.contains("limit=50"))
        #expect(url.contains("before=123"))
    }

    @Test func setsJSONContentTypeForBodies() async throws {
        let client = APIClient()
        let request = try await client.makeRequest(
            "POST",
            Endpoint.login,
            bodyData: Data("{}".utf8)
        )
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}

@Suite("Endpoint paths")
struct EndpointTests {
    @Test func messagePathsIncludeIDs() {
        let path = Endpoint.message(Snowflake(1), Snowflake(2))
        #expect(path == "/channels/1/messages/2")
    }

    @Test func authPathsMatchUpstream() {
        #expect(Endpoint.login == "/auth/login")
        #expect(Endpoint.loginMfaTotp == "/auth/login/mfa/totp")
    }
}
