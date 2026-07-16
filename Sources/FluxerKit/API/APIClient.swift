import Foundation

public enum APIError: Error, Sendable {
    case invalidURL(String)
    case httpError(status: Int, code: String?, message: String?)
    case unauthorized
    case captchaRequired
    case invalidCaptcha
    case rateLimited(retryAfter: TimeInterval?)
    case decodingFailed(underlying: String)

    /// Maps a non-success HTTP response to a typed error using the
    /// {code, message} JSON shape the Fluxer API returns.
    static func from(status: Int, data: Data) -> APIError {
        struct ErrorBody: Decodable {
            let code: String?
            let message: String?
        }
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch body?.code {
        case "CAPTCHA_REQUIRED":
            return .captchaRequired
        case "INVALID_CAPTCHA", "CAPTCHA_INVALID":
            return .invalidCaptcha
        default:
            break
        }
        switch status {
        case 401:
            return .unauthorized
        default:
            return .httpError(status: status, code: body?.code, message: body?.message)
        }
    }
}

/// A solved captcha challenge, passed along with login or registration.
public struct CaptchaSolution: Sendable {
    public let token: String
    public let type: String

    public init(token: String, type: String = "hcaptcha") {
        self.token = token
        self.type = type
    }
}

public enum Credential: Sendable {
    case user(token: String)
    case bot(token: String)

    var headerValue: String {
        switch self {
        case .user(let token): return token
        case .bot(let token): return "Bot \(token)"
        }
    }
}

/// Result of a password login. Either we got a token straight away, the
/// account has MFA enabled, or the server wants this new device confirmed
/// through a link it emailed to the account address.
public enum LoginResult: Sendable, Equatable {
    case success(token: String)
    case mfaRequired(ticket: String, totp: Bool, webauthn: Bool)
    case ipAuthorizationRequired(ticket: String, email: String)
}

/// The wire shape of a login response, a union of three variants.
struct LoginResponseBody: Decodable {
    var token: String?
    var ticket: String?
    var mfa: Bool?
    var totp: Bool?
    var webauthn: Bool?
    var ipAuthorizationRequired: Bool?
    var email: String?
}

extension LoginResult {
    static func interpret(_ body: LoginResponseBody) throws -> LoginResult {
        if let token = body.token, !token.isEmpty {
            return .success(token: token)
        }
        if body.ipAuthorizationRequired == true, let ticket = body.ticket {
            return .ipAuthorizationRequired(ticket: ticket, email: body.email ?? "")
        }
        if body.mfa == true, let ticket = body.ticket {
            return .mfaRequired(ticket: ticket, totp: body.totp ?? false, webauthn: body.webauthn ?? false)
        }
        throw APIError.decodingFailed(underlying: "Login response matched no known variant")
    }
}

/// Status of a pending new-device email confirmation.
public struct IpAuthorizationStatus: Decodable, Sendable {
    public let completed: Bool
    public let token: String?
}

/// A browser login handoff: the app shows this code, the person signs in
/// on the web and enters it there, then the app polls for the token.
public struct HandoffInitiation: Decodable, Sendable {
    public let code: String
    public let expiresAt: String
}

public struct HandoffStatus: Decodable, Sendable {
    public let status: String
    public let token: String?

    public var isCompleted: Bool { status == "completed" }
    public var isExpired: Bool { status == "expired" }
}

/// REST client for a Fluxer instance. Defaults to fluxer.app but any
/// self-hosted instance works by passing its API base URL.
public actor APIClient {
    public static let defaultBaseURL = URL(string: "https://api.fluxer.app/v1")!

    private let baseURL: URL
    private let session: URLSession
    private var credential: Credential?

    public init(baseURL: URL = APIClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func setCredential(_ credential: Credential?) {
        self.credential = credential
    }

    public var isAuthenticated: Bool {
        credential != nil
    }

    // MARK: Auth

    public func login(
        email: String,
        password: String,
        captcha: CaptchaSolution? = nil
    ) async throws -> LoginResult {
        struct Body: Encodable {
            let email: String
            let password: String
        }
        var headers: [String: String] = [:]
        if let captcha {
            headers["x-captcha-token"] = captcha.token
            headers["x-captcha-type"] = captcha.type
        }
        let response: LoginResponseBody = try await send(
            "POST",
            Endpoint.login,
            body: Body(email: email, password: password),
            headers: headers
        )
        let result = try LoginResult.interpret(response)
        if case .success(let token) = result {
            credential = .user(token: token)
        }
        return result
    }

    /// Checks whether the new-device email confirmation has been completed.
    /// Once it has, the returned token is installed as the credential.
    public func pollIpAuthorization(ticket: String) async throws -> IpAuthorizationStatus {
        let status: IpAuthorizationStatus = try await send(
            "GET",
            Endpoint.ipAuthorizationPoll,
            query: [URLQueryItem(name: "ticket", value: ticket)]
        )
        if status.completed, let token = status.token, !token.isEmpty {
            credential = .user(token: token)
        }
        return status
    }

    public func resendIpAuthorization(ticket: String) async throws {
        struct Body: Encodable {
            let ticket: String
        }
        let data = try JSONEncoder.fluxer.encode(Body(ticket: ticket))
        let request = try makeRequest("POST", Endpoint.ipAuthorizationResend, bodyData: data)
        _ = try await executeRaw(request)
    }

    // MARK: Browser login handoff

    public func initiateHandoff() async throws -> HandoffInitiation {
        try await send("POST", Endpoint.handoffInitiate)
    }

    /// Checks whether the browser side has approved the handoff yet.
    /// On completion the returned token becomes the credential.
    public func pollHandoff(code: String) async throws -> HandoffStatus {
        let status: HandoffStatus = try await send("GET", Endpoint.handoffStatus(code))
        if status.isCompleted, let token = status.token, !token.isEmpty {
            credential = .user(token: token)
        }
        return status
    }

    public func cancelHandoff(code: String) async throws {
        let request = try makeRequest("DELETE", Endpoint.handoffCancel(code))
        _ = try await executeRaw(request)
    }

    public func loginMfaTotp(code: String, ticket: String) async throws -> String {
        struct Body: Encodable {
            let code: String
            let ticket: String
        }
        struct Response: Decodable {
            let token: String
        }
        let response: Response = try await send("POST", Endpoint.loginMfaTotp, body: Body(code: code, ticket: ticket))
        credential = .user(token: response.token)
        return response.token
    }

    public func logout() async throws {
        try await sendExpectingNoContent("POST", Endpoint.logout)
        credential = nil
    }

    // MARK: Users and guilds

    public func currentUser() async throws -> User {
        try await send("GET", Endpoint.me)
    }

    public func myGuilds() async throws -> [Guild] {
        try await send("GET", Endpoint.myGuilds)
    }

    public func guildChannels(_ guildId: Snowflake) async throws -> [Channel] {
        try await send("GET", Endpoint.guildChannels(guildId))
    }

    public func myChannels() async throws -> [Channel] {
        try await send("GET", Endpoint.myChannels)
    }

    // MARK: Messages

    public func messages(
        in channelId: Snowflake,
        before: Snowflake? = nil,
        limit: Int = 50
    ) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            query.append(URLQueryItem(name: "before", value: before.stringValue))
        }
        return try await send("GET", Endpoint.messages(channelId), query: query)
    }

    public func sendMessage(_ content: String, to channelId: Snowflake, nonce: String? = nil) async throws -> Message {
        struct Body: Encodable {
            let content: String
            let nonce: String?
        }
        return try await send("POST", Endpoint.messages(channelId), body: Body(content: content, nonce: nonce))
    }

    public func editMessage(_ messageId: Snowflake, in channelId: Snowflake, content: String) async throws -> Message {
        struct Body: Encodable {
            let content: String
        }
        return try await send("PATCH", Endpoint.message(channelId, messageId), body: Body(content: content))
    }

    public func deleteMessage(_ messageId: Snowflake, in channelId: Snowflake) async throws {
        try await sendExpectingNoContent("DELETE", Endpoint.message(channelId, messageId))
    }

    public func triggerTyping(in channelId: Snowflake) async throws {
        try await sendExpectingNoContent("POST", Endpoint.typing(channelId))
    }

    /// Marks everything up to the given message as read.
    public func ackMessage(_ messageId: Snowflake, in channelId: Snowflake) async throws {
        struct Body: Encodable {
            let mentionCount: Int
        }
        let data = try JSONEncoder.fluxer.encode(Body(mentionCount: 0))
        let request = try makeRequest("POST", Endpoint.ack(channelId, messageId), bodyData: data)
        _ = try await executeRaw(request)
    }

    // MARK: Request plumbing

    func makeRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        bodyData: Data? = nil,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString)
        }
        components.path += path
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.invalidURL(baseURL.absoluteString + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let credential {
            request.setValue(credential.headerValue, forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let request = try makeRequest(method, path, query: query)
        return try await execute(request)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try JSONEncoder.fluxer.encode(body)
        let request = try makeRequest(method, path, query: query, bodyData: data, headers: headers)
        return try await execute(request)
    }

    private func sendExpectingNoContent(_ method: String, _ path: String) async throws {
        let request = try makeRequest(method, path)
        _ = try await executeRaw(request)
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await executeRaw(request)
        do {
            return try JSONDecoder.fluxer.decode(Response.self, from: data)
        } catch {
            throw APIError.decodingFailed(underlying: String(describing: error))
        }
    }

    private func executeRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(status: -1, code: nil, message: "Not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        default:
            throw APIError.from(status: http.statusCode, data: data)
        }
    }
}
