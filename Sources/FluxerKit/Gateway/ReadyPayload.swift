import Foundation

/// A guild as delivered inside READY: the guild object itself sits under
/// `properties`, with channels and counts alongside it.
public struct ReadyGuild: Codable, Sendable {
    public let id: Snowflake
    public var properties: Guild
    public var channels: [Channel]?
    public var memberCount: Int?
    public var unavailable: Bool?

    /// Flattens the wrapper into a Guild with its channels attached.
    public func asGuild() -> Guild {
        var guild = properties
        guild.channels = channels
        guild.memberCount = memberCount
        guild.unavailable = unavailable
        return guild
    }
}

/// The parts of the READY dispatch this client uses. The full payload
/// carries much more (settings, presences, read states) which can be
/// picked up later without breaking decoding.
public struct ReadyPayload: Codable, Sendable {
    public let sessionId: String
    public var user: User
    public var guilds: [ReadyGuild]
    public var privateChannels: [Channel]?
    public var resumeGatewayUrl: String?
}
