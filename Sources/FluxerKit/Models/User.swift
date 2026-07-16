import Foundation

public struct User: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var username: String
    public var discriminator: String?
    public var globalName: String?
    public var avatar: String?
    public var bot: Bool?
    public var system: Bool?
    public var email: String?
    public var verified: Bool?
    public var mfaEnabled: Bool?
    public var flags: Int?

    /// The name to show in UI, preferring the display name over the login name.
    public var displayName: String {
        globalName ?? username
    }
}
