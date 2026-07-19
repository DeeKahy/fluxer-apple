import Foundation

/// Someone's occupancy of a voice channel, from READY guilds and
/// VOICE_STATE_UPDATE dispatches. A nil channel means they left.
public struct VoiceState: Codable, Sendable {
    public var userId: Snowflake
    public var channelId: Snowflake?
    public var guildId: Snowflake?
    public var selfMute: Bool?
    public var selfDeaf: Bool?
    /// Server-side mute and deafen, set by moderators.
    public var mute: Bool?
    public var deaf: Bool?

    /// Muted from everyone else's point of view, self or server imposed.
    public var isMuted: Bool {
        selfMute == true || mute == true
    }
}

/// Where to connect for media after asking to join voice: a LiveKit
/// endpoint and access token.
public struct VoiceServerUpdate: Codable, Sendable {
    public var token: String
    public var endpoint: String
    public var connectionId: String?
    public var guildId: Snowflake?
    public var channelId: Snowflake?

    /// The endpoint as a websocket URL, with the scheme added when the
    /// server sends a bare host.
    public var url: URL? {
        if endpoint.contains("://") {
            return URL(string: endpoint)
        }
        return URL(string: "wss://" + endpoint)
    }
}
