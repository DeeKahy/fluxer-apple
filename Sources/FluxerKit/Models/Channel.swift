import Foundation

public struct Channel: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Int, Codable, Sendable {
        case guildText = 0
        case dm = 1
        case guildVoice = 2
        case groupDM = 3
        case guildCategory = 4
        case unknown = -1

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(Int.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public let id: Snowflake
    public var type: Kind
    public var guildId: Snowflake?
    public var name: String?
    public var topic: String?
    public var position: Int?
    public var parentId: Snowflake?
    public var lastMessageId: Snowflake?
    public var recipients: [User]?
    public var nsfw: Bool?
}
