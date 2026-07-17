import Foundation

public struct EmbedMedia: Codable, Hashable, Sendable {
    public var url: String?
    public var proxyUrl: String?
    public var width: Int?
    public var height: Int?
}

public struct EmbedAuthor: Codable, Hashable, Sendable {
    public var name: String?
    public var url: String?
    public var iconUrl: String?
}

public struct EmbedFooter: Codable, Hashable, Sendable {
    public var text: String?
    public var iconUrl: String?
}

public struct EmbedField: Codable, Hashable, Sendable {
    public var name: String?
    public var value: String?
    public var inline: Bool?
}

public struct Embed: Codable, Hashable, Sendable {
    public var type: String?
    public var url: String?
    public var title: String?
    public var description: String?
    public var color: Int?
    public var author: EmbedAuthor?
    public var image: EmbedMedia?
    public var thumbnail: EmbedMedia?
    public var footer: EmbedFooter?
    public var fields: [EmbedField]?
}

public struct GuildEmoji: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var name: String
    public var animated: Bool?

    public var asReactionEmoji: ReactionEmoji {
        ReactionEmoji(id: id, name: name, animated: animated)
    }

    /// The token typed into message content.
    public var messageToken: String {
        (animated == true ? "<a:" : "<:") + name + ":\(id)>"
    }
}
