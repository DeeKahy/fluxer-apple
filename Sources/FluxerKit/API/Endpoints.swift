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
}
