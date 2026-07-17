import Foundation

/// A guild as delivered inside READY: the guild object itself sits under
/// `properties`, with channels and counts alongside it.
public struct ReadyGuild: Codable, Sendable {
    public let id: Snowflake
    public var properties: Guild
    public var channels: [Channel]?
    public var roles: [Role]?
    public var emojis: [GuildEmoji]?
    public var members: [GuildMember]?
    public var voiceStates: [VoiceState]?
    public var memberCount: Int?
    public var unavailable: Bool?

    /// Flattens the wrapper into a Guild with its channels and roles attached.
    public func asGuild() -> Guild {
        var guild = properties
        guild.channels = channels
        guild.roles = roles
        guild.emojis = emojis
        guild.memberCount = memberCount
        guild.unavailable = unavailable
        return guild
    }
}

public struct Relationship: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Int, Codable, Sendable {
        case friend = 1
        case blocked = 2
        case incomingRequest = 3
        case outgoingRequest = 4
        case unknown = -1

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(Int.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public let id: Snowflake
    public var type: Kind
    public var user: User?
    public var since: String?
    public var nickname: String?
}

/// Per channel read position, as delivered in READY and ack responses.
public struct ReadState: Codable, Sendable {
    public let id: Snowflake
    public var lastMessageId: Snowflake?
    public var mentionCount: Int?
}

/// The parts of the READY dispatch this client uses. The full payload
/// carries much more (settings, presences) which can be picked up later
/// without breaking decoding.
public struct ReadyPayload: Codable, Sendable {
    public let sessionId: String
    public var user: User
    public var guilds: [ReadyGuild]
    public var privateChannels: [Channel]?
    public var readStates: [ReadState]?
    public var users: [User]?
    public var relationships: [Relationship]?
    public var resumeGatewayUrl: String?
}
