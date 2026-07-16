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

@Suite("Login response interpretation")
struct LoginResponseTests {
    private func interpret(_ json: String) throws -> LoginResult {
        let body = try JSONDecoder.fluxer.decode(LoginResponseBody.self, from: Data(json.utf8))
        return try LoginResult.interpret(body)
    }

    @Test func tokenResponseIsSuccess() throws {
        let result = try interpret(#"{"token": "tok123", "user_id": "1", "user": {"id": "1", "username": "dee"}}"#)
        #expect(result == .success(token: "tok123"))
    }

    @Test func mfaResponseCarriesMethods() throws {
        let result = try interpret(
            #"{"mfa": true, "ticket": "t1", "allowed_methods": ["totp"], "totp": true, "webauthn": false}"#
        )
        #expect(result == .mfaRequired(ticket: "t1", totp: true, webauthn: false))
    }

    @Test func newDeviceResponseIsIpAuthorization() throws {
        let result = try interpret(
            #"{"ip_authorization_required": true, "ticket": "t2", "email": "d@example.com"}"#
        )
        #expect(result == .ipAuthorizationRequired(ticket: "t2", email: "d@example.com"))
    }

    @Test func ipAuthorizationWinsOverBareTicket() throws {
        // A ticket alone must never be mistaken for an MFA prompt.
        let body = try JSONDecoder.fluxer.decode(
            LoginResponseBody.self,
            from: Data(#"{"ticket": "t3"}"#.utf8)
        )
        #expect(throws: APIError.self) {
            try LoginResult.interpret(body)
        }
    }
}

@Suite("API error mapping")
struct APIErrorMappingTests {
    @Test func mapsCaptchaRequired() {
        let body = Data(#"{"code":"CAPTCHA_REQUIRED","message":"Captcha is required."}"#.utf8)
        let error = APIError.from(status: 400, data: body)
        guard case .captchaRequired = error else {
            Issue.record("Expected captchaRequired, got \(error)")
            return
        }
    }

    @Test func mapsUnauthorized() {
        let error = APIError.from(status: 401, data: Data("{}".utf8))
        guard case .unauthorized = error else {
            Issue.record("Expected unauthorized, got \(error)")
            return
        }
    }

    @Test func keepsCodeAndMessageForOtherErrors() {
        let body = Data(#"{"code":"NOT_FOUND","message":"Not found."}"#.utf8)
        let error = APIError.from(status: 404, data: body)
        guard case .httpError(let status, let code, let message) = error else {
            Issue.record("Expected httpError, got \(error)")
            return
        }
        #expect(status == 404)
        #expect(code == "NOT_FOUND")
        #expect(message == "Not found.")
    }

    @Test func survivesNonJSONBodies() {
        let error = APIError.from(status: 502, data: Data("Bad Gateway".utf8))
        guard case .httpError(let status, _, _) = error else {
            Issue.record("Expected httpError, got \(error)")
            return
        }
        #expect(status == 502)
    }
}

@Suite("APIClient captcha headers")
struct APIClientCaptchaTests {
    @Test func captchaHeadersRideAlong() async throws {
        let client = APIClient()
        let request = try await client.makeRequest(
            "POST",
            Endpoint.login,
            bodyData: Data("{}".utf8),
            headers: ["x-captcha-token": "solved", "x-captcha-type": "hcaptcha"]
        )
        #expect(request.value(forHTTPHeaderField: "x-captcha-token") == "solved")
        #expect(request.value(forHTTPHeaderField: "x-captcha-type") == "hcaptcha")
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
