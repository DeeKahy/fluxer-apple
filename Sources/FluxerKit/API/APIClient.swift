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

    public func guildMembers(
        _ guildId: Snowflake,
        limit: Int = 100,
        after: Snowflake? = nil
    ) async throws -> [GuildMember] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let after {
            query.append(URLQueryItem(name: "after", value: after.stringValue))
        }
        return try await send("GET", Endpoint.guildMembers(guildId), query: query)
    }

    /// Opens (or returns the existing) DM channel with a user.
    public func openDM(with userId: Snowflake) async throws -> Channel {
        struct Body: Encodable {
            let recipientId: Snowflake
        }
        return try await send("POST", Endpoint.myChannels, body: Body(recipientId: userId))
    }

    // MARK: Relationships

    public func relationships() async throws -> [Relationship] {
        try await send("GET", Endpoint.myRelationships)
    }

    /// Sends a friend request straight to a known user id.
    public func sendFriendRequest(to userId: Snowflake) async throws {
        let data = Data("{}".utf8)
        let request = try makeRequest("POST", Endpoint.relationship(userId), bodyData: data)
        _ = try await executeRaw(request)
    }

    /// Sends a friend request by username (and optional discriminator).
    public func sendFriendRequest(username: String, discriminator: String?) async throws {
        struct Body: Encodable {
            let username: String
            let discriminator: String?
        }
        let data = try JSONEncoder.fluxer.encode(Body(username: username, discriminator: discriminator))
        let request = try makeRequest("POST", Endpoint.myRelationships, bodyData: data)
        _ = try await executeRaw(request)
    }

    public func acceptFriendRequest(from userId: Snowflake) async throws {
        let request = try makeRequest("PUT", Endpoint.relationship(userId))
        _ = try await executeRaw(request)
    }

    /// Removes a friend, cancels a request, or unblocks.
    public func removeRelationship(with userId: Snowflake) async throws {
        let request = try makeRequest("DELETE", Endpoint.relationship(userId))
        _ = try await executeRaw(request)
    }

    public func blockUser(_ userId: Snowflake) async throws {
        struct Body: Encodable {
            let type: Int
        }
        let data = try JSONEncoder.fluxer.encode(Body(type: Relationship.Kind.blocked.rawValue))
        let request = try makeRequest("PUT", Endpoint.relationship(userId), bodyData: data)
        _ = try await executeRaw(request)
    }

    // MARK: Messages

    public func messages(
        in channelId: Snowflake,
        before: Snowflake? = nil,
        after: Snowflake? = nil,
        around: Snowflake? = nil,
        limit: Int = 50
    ) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            query.append(URLQueryItem(name: "before", value: before.stringValue))
        }
        if let after {
            query.append(URLQueryItem(name: "after", value: after.stringValue))
        }
        if let around {
            query.append(URLQueryItem(name: "around", value: around.stringValue))
        }
        return try await send("GET", Endpoint.messages(channelId), query: query)
    }

    struct MessageReferencePayload: Encodable {
        let messageId: Snowflake
    }

    struct MessageCreateBody: Encodable {
        let content: String
        let nonce: String?
        let messageReference: MessageReferencePayload?
    }

    public func sendMessage(
        _ content: String,
        to channelId: Snowflake,
        replyTo: Snowflake? = nil,
        nonce: String? = nil
    ) async throws -> Message {
        let body = MessageCreateBody(
            content: content,
            nonce: nonce,
            messageReference: replyTo.map(MessageReferencePayload.init)
        )
        return try await send("POST", Endpoint.messages(channelId), body: body)
    }

    /// A file staged for upload alongside a message.
    public struct UploadFile: Sendable {
        public let filename: String
        public let data: Data
        public let contentType: String

        public init(filename: String, data: Data, contentType: String) {
            self.filename = filename
            self.data = data
            self.contentType = contentType
        }
    }

    /// Sends a message with attached files as one multipart request:
    /// a payload_json part plus files[N] parts, same as the web client's
    /// non-presigned upload path.
    public func sendMessage(
        _ content: String,
        to channelId: Snowflake,
        files: [UploadFile],
        replyTo: Snowflake? = nil,
        nonce: String? = nil
    ) async throws -> Message {
        let payload = MessageCreateBody(
            content: content,
            nonce: nonce,
            messageReference: replyTo.map(MessageReferencePayload.init)
        )
        let payloadData = try JSONEncoder.fluxer.encode(payload)

        let boundary = "FluxerKit-\(UUID().uuidString)"
        var body = Data()
        func appendPart(_ string: String) {
            body.append(Data(string.utf8))
        }
        appendPart("--\(boundary)\r\n")
        appendPart("Content-Disposition: form-data; name=\"payload_json\"\r\n")
        appendPart("Content-Type: application/json\r\n\r\n")
        body.append(payloadData)
        appendPart("\r\n")
        for (index, file) in files.enumerated() {
            let safeName = file.filename.replacingOccurrences(of: "\"", with: "_")
            appendPart("--\(boundary)\r\n")
            appendPart("Content-Disposition: form-data; name=\"files[\(index)]\"; filename=\"\(safeName)\"\r\n")
            appendPart("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            appendPart("\r\n")
        }
        appendPart("--\(boundary)--\r\n")

        var request = try makeRequest("POST", Endpoint.messages(channelId))
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data = try await executeRaw(request)
        do {
            return try JSONDecoder.fluxer.decode(Message.self, from: data)
        } catch {
            throw APIError.decodingFailed(underlying: String(describing: error))
        }
    }

    public func addReaction(_ emoji: ReactionEmoji, to messageId: Snowflake, in channelId: Snowflake) async throws {
        let request = try makeRequest("PUT", Endpoint.myReaction(channelId, messageId, emoji.apiValue))
        _ = try await executeRaw(request)
    }

    public func removeReaction(_ emoji: ReactionEmoji, from messageId: Snowflake, in channelId: Snowflake) async throws {
        let request = try makeRequest("DELETE", Endpoint.myReaction(channelId, messageId, emoji.apiValue))
        _ = try await executeRaw(request)
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

    // MARK: Pins, saved messages, mentions

    /// The pins list arrives either as a bare array or wrapped in a
    /// container; both are handled.
    public func pinnedMessages(in channelId: Snowflake) async throws -> [Message] {
        let request = try makeRequest("GET", Endpoint.pins(channelId))
        let data = try await executeRaw(request)
        return Self.extractMessages(from: data)
    }

    public func pinMessage(_ messageId: Snowflake, in channelId: Snowflake) async throws {
        let request = try makeRequest("PUT", Endpoint.pin(channelId, messageId))
        _ = try await executeRaw(request)
    }

    public func unpinMessage(_ messageId: Snowflake, in channelId: Snowflake) async throws {
        let request = try makeRequest("DELETE", Endpoint.pin(channelId, messageId))
        _ = try await executeRaw(request)
    }

    public func savedMessages() async throws -> [Message] {
        let request = try makeRequest("GET", Endpoint.savedMessages)
        let data = try await executeRaw(request)
        return Self.extractMessages(from: data)
    }

    /// Saving is a POST with the channel and message ids in the body;
    /// the per-message path only exists for DELETE.
    public func saveMessage(_ messageId: Snowflake, in channelId: Snowflake) async throws {
        struct Body: Encodable {
            let channelId: Snowflake
            let messageId: Snowflake
        }
        let data = try JSONEncoder.fluxer.encode(Body(channelId: channelId, messageId: messageId))
        let request = try makeRequest("POST", Endpoint.savedMessages, bodyData: data)
        _ = try await executeRaw(request)
    }

    public func unsaveMessage(_ messageId: Snowflake) async throws {
        let request = try makeRequest("DELETE", Endpoint.savedMessage(messageId))
        _ = try await executeRaw(request)
    }

    public func mentions(limit: Int = 50) async throws -> [Message] {
        let request = try makeRequest("GET", Endpoint.mentions, query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let data = try await executeRaw(request)
        return Self.extractMessages(from: data)
    }

    /// Pulls message objects out of a response that may be a plain array,
    /// or an object wrapping the array, or entries wrapping each message.
    static func extractMessages(from data: Data) -> [Message] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        let array = value.arrayValue
            ?? value["items"]?.arrayValue
            ?? value["messages"]?.arrayValue
            ?? value["mentions"]?.arrayValue
            ?? []
        return array.compactMap { entry in
            // Wrapper entries (saved messages, pins) carry the real message
            // under a "message" key and would otherwise half-decode as a
            // Message themselves, so check the key first.
            if let inner = entry["message"] {
                return try? inner.decoded(as: Message.self)
            }
            return try? entry.decoded(as: Message.self)
        }
    }

    public func deleteMention(_ messageId: Snowflake) async throws {
        try await sendExpectingNoContent("DELETE", Endpoint.mention(messageId))
    }

    public func markMentionsRead(_ messageIds: [Snowflake]) async throws {
        struct Body: Encodable {
            let messageIds: [Snowflake]
        }
        let data = try JSONEncoder.fluxer.encode(Body(messageIds: messageIds))
        let request = try makeRequest("POST", Endpoint.mentionsRead, bodyData: data)
        _ = try await executeRaw(request)
    }

    // MARK: Search

    public struct MessageSearchResults: Sendable {
        public var messages: [Message]
        public var channels: [Channel]
        public var total: Int
        /// True while the server is still building its search index; results
        /// are empty and the client should say so instead of "no matches".
        public var indexing: Bool

        public init(messages: [Message] = [], channels: [Channel] = [], total: Int = 0, indexing: Bool = false) {
            self.messages = messages
            self.channels = channels
            self.total = total
            self.indexing = indexing
        }
    }

    /// Global message search. The response is either a results object or
    /// {indexing: true} while the server builds its index.
    public func searchMessages(content: String, limit: Int = 25) async throws -> MessageSearchResults {
        struct Body: Encodable {
            let content: String
            let hitsPerPage: Int
        }
        let data = try JSONEncoder.fluxer.encode(Body(content: content, hitsPerPage: limit))
        let request = try makeRequest("POST", Endpoint.searchMessages, bodyData: data)
        let responseData = try await executeRaw(request)
        return Self.extractSearchResults(from: responseData)
    }

    static func extractSearchResults(from data: Data) -> MessageSearchResults {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return MessageSearchResults()
        }
        if value["indexing"]?.boolValue == true {
            return MessageSearchResults(indexing: true)
        }
        let messages = (value["messages"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: Message.self) }
        let channels = (value["channels"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: Channel.self) }
        let total = value["total"]?.intValue ?? messages.count
        return MessageSearchResults(messages: messages, channels: channels, total: total)
    }

    // MARK: Profiles, sessions

    public struct UserProfile: Decodable, Sendable {
        public var bio: String?
        public var pronouns: String?
        public var user: User?
    }

    public func profile(of userId: Snowflake) async throws -> UserProfile {
        try await send("GET", Endpoint.profile(userId))
    }

    public struct AuthSession: Decodable, Sendable, Identifiable {
        public struct ClientInfo: Decodable, Sendable {
            public var platform: String?
            public var os: String?
            public var browser: String?
        }

        public var idHash: String
        public var clientInfo: ClientInfo?
        public var maskedIp: String?
        public var approxLastUsedAt: String?
        public var current: Bool

        public var id: String { idHash }
    }

    public func sessions() async throws -> [AuthSession] {
        try await send("GET", Endpoint.sessions)
    }

    public func logoutSessions(idHashes: [String]) async throws {
        struct Body: Encodable {
            let sessionIdHashes: [String]
        }
        let data = try JSONEncoder.fluxer.encode(Body(sessionIdHashes: idHashes))
        let request = try makeRequest("POST", Endpoint.sessionsLogout, bodyData: data)
        _ = try await executeRaw(request)
    }

    // MARK: Guilds and invites

    public struct Invite: Decodable, Sendable {
        public var code: String
        public var guild: Guild?
        public var channel: Channel?
    }

    public func createInvite(in channelId: Snowflake) async throws -> Invite {
        struct Body: Encodable {}
        return try await send("POST", Endpoint.channelInvites(channelId), body: Body())
    }

    public func inviteInfo(_ code: String) async throws -> Invite {
        try await send("GET", Endpoint.invite(code))
    }

    public func acceptInvite(_ code: String) async throws -> Invite {
        struct Body: Encodable {}
        return try await send("POST", Endpoint.invite(code), body: Body())
    }

    public func createGuild(name: String) async throws -> Guild {
        struct Body: Encodable {
            let name: String
        }
        return try await send("POST", Endpoint.guilds, body: Body(name: name))
    }

    public func leaveGuild(_ guildId: Snowflake) async throws {
        let request = try makeRequest("DELETE", Endpoint.leaveGuild(guildId))
        _ = try await executeRaw(request)
    }

    public func kickMember(_ userId: Snowflake, from guildId: Snowflake) async throws {
        let request = try makeRequest("DELETE", Endpoint.guildMember(guildId, userId))
        _ = try await executeRaw(request)
    }

    public func banMember(_ userId: Snowflake, from guildId: Snowflake) async throws {
        let request = try makeRequest("PUT", Endpoint.guildBan(guildId, userId))
        _ = try await executeRaw(request)
    }

    // MARK: Voice

    /// Keeps the server's voice presence alive; the official client pings
    /// every fifteen seconds while connected. The server rejects the call
    /// without the connection id from VOICE_SERVER_UPDATE.
    public func voiceHeartbeat(in channelId: Snowflake, connectionId: String) async throws {
        struct Body: Encodable {
            let connectionId: String
        }
        let data = try JSONEncoder.fluxer.encode(Body(connectionId: connectionId))
        let request = try makeRequest("POST", Endpoint.voiceHeartbeat(channelId), bodyData: data)
        _ = try await executeRaw(request)
    }

    /// Tells the server this voice connection's presence ended, called on
    /// a clean leave so others see the departure right away.
    public func endVoiceHeartbeat(in channelId: Snowflake, connectionId: String) async throws {
        struct Body: Encodable {
            let connectionId: String
        }
        let data = try JSONEncoder.fluxer.encode(Body(connectionId: connectionId))
        let request = try makeRequest("DELETE", Endpoint.voiceHeartbeat(channelId), bodyData: data)
        _ = try await executeRaw(request)
    }

    /// Rings the other side of a DM call.
    public func ringCall(in channelId: Snowflake) async throws {
        let data = Data("{}".utf8)
        let request = try makeRequest("POST", Endpoint.callRing(channelId), bodyData: data)
        _ = try await executeRaw(request)
    }

    public func stopRinging(in channelId: Snowflake, recipients: [Snowflake]? = nil) async throws {
        struct Body: Encodable {
            let recipients: [Snowflake]?
        }
        let data = try JSONEncoder.fluxer.encode(Body(recipients: recipients))
        let request = try makeRequest("POST", Endpoint.callStopRinging(channelId), bodyData: data)
        _ = try await executeRaw(request)
    }

    public func setDMPinned(_ channelId: Snowflake, pinned: Bool) async throws {
        let request = try makeRequest(pinned ? "PUT" : "DELETE", Endpoint.dmPin(channelId))
        _ = try await executeRaw(request)
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
