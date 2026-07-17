import Foundation

/// REST paths, mirroring fluxer_app/src/features/app/constants/Endpoints.ts upstream.
/// Paths are relative to the API base, which already includes the version segment.
enum Endpoint {
    static let login = "/auth/login"
    static let loginMfaTotp = "/auth/login/mfa/totp"
    static let logout = "/auth/logout"
    static let ipAuthorizationPoll = "/auth/ip-authorization/poll"
    static let ipAuthorizationResend = "/auth/ip-authorization/resend"
    static let handoffInitiate = "/auth/handoff/initiate"

    static func handoffStatus(_ code: String) -> String { "/auth/handoff/\(code)/status" }
    static func handoffCancel(_ code: String) -> String { "/auth/handoff/\(code)" }
    static let me = "/users/@me"
    static let myChannels = "/users/@me/channels"
    static let myGuilds = "/users/@me/guilds"

    static func user(_ id: Snowflake) -> String { "/users/\(id)" }
    static func guild(_ id: Snowflake) -> String { "/guilds/\(id)" }
    static func guildChannels(_ id: Snowflake) -> String { "/guilds/\(id)/channels" }
    static func guildMembers(_ id: Snowflake) -> String { "/guilds/\(id)/members" }
    static let myRelationships = "/users/@me/relationships"
    static func relationship(_ userId: Snowflake) -> String { "/users/@me/relationships/\(userId)" }
    static func channel(_ id: Snowflake) -> String { "/channels/\(id)" }
    static func messages(_ channelId: Snowflake) -> String { "/channels/\(channelId)/messages" }
    static func message(_ channelId: Snowflake, _ messageId: Snowflake) -> String {
        "/channels/\(channelId)/messages/\(messageId)"
    }
    static func typing(_ channelId: Snowflake) -> String { "/channels/\(channelId)/typing" }
    static func myReaction(_ channelId: Snowflake, _ messageId: Snowflake, _ emoji: String) -> String {
        "/channels/\(channelId)/messages/\(messageId)/reactions/\(emoji)/@me"
    }
    static func ack(_ channelId: Snowflake, _ messageId: Snowflake) -> String {
        "/channels/\(channelId)/messages/\(messageId)/ack"
    }
    static func pins(_ channelId: Snowflake) -> String { "/channels/\(channelId)/messages/pins" }
    static func pin(_ channelId: Snowflake, _ messageId: Snowflake) -> String {
        "/channels/\(channelId)/pins/\(messageId)"
    }
    static let savedMessages = "/users/@me/saved-messages"
    static func savedMessage(_ messageId: Snowflake) -> String { "/users/@me/saved-messages/\(messageId)" }
    static let mentions = "/users/@me/mentions"
    static let sessions = "/auth/sessions"
    static let sessionsLogout = "/auth/sessions/logout"
    static func profile(_ userId: Snowflake) -> String { "/users/\(userId)/profile" }
    static func channelInvites(_ channelId: Snowflake) -> String { "/channels/\(channelId)/invites" }
    static func invite(_ code: String) -> String { "/invites/\(code)" }
    static let guilds = "/guilds"
    static func leaveGuild(_ guildId: Snowflake) -> String { "/users/@me/guilds/\(guildId)" }
    static func guildMember(_ guildId: Snowflake, _ userId: Snowflake) -> String {
        "/guilds/\(guildId)/members/\(userId)"
    }
    static func guildBan(_ guildId: Snowflake, _ userId: Snowflake) -> String {
        "/guilds/\(guildId)/bans/\(userId)"
    }
    static func dmPin(_ channelId: Snowflake) -> String { "/users/@me/channels/\(channelId)/pin" }
    static func voiceHeartbeat(_ channelId: Snowflake) -> String {
        "/channels/\(channelId)/voice-presence/heartbeat"
    }
    static func callRing(_ channelId: Snowflake) -> String { "/channels/\(channelId)/call/ring" }
    static func callStopRinging(_ channelId: Snowflake) -> String { "/channels/\(channelId)/call/stop-ringing" }
}
