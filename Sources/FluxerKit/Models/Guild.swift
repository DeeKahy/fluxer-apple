import Foundation

public struct Guild: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var name: String
    public var icon: String?
    public var description: String?
    public var ownerId: Snowflake?
    public var channels: [Channel]?
    public var memberCount: Int?
    public var unavailable: Bool?
}
