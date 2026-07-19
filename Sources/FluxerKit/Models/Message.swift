import Foundation

public struct Attachment: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var filename: String
    public var size: Int?
    public var url: String?
    public var proxyUrl: String?
    public var contentType: String?
    public var width: Int?
    public var height: Int?
}

public struct ReactionEmoji: Codable, Hashable, Sendable {
    public var id: Snowflake?
    public var name: String
    public var animated: Bool?

    public init(id: Snowflake? = nil, name: String, animated: Bool? = nil) {
        self.id = id
        self.name = name
        self.animated = animated
    }

    /// The form used in reaction endpoint paths: the character itself for
    /// unicode emoji, name:id for custom emoji.
    public var apiValue: String {
        if let id {
            return "\(name):\(id)"
        }
        return name
    }

    /// Identity for merging reaction updates.
    public var key: String { apiValue }
}

public struct Reaction: Codable, Hashable, Sendable {
    public var emoji: ReactionEmoji
    public var count: Int
    public var me: Bool?

    public init(emoji: ReactionEmoji, count: Int, me: Bool? = nil) {
        self.emoji = emoji
        self.count = count
        self.me = me
    }
}

public struct Message: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var channelId: Snowflake
    public var guildId: Snowflake?
    public var author: User?
    public var content: String?
    public var timestamp: Date?
    public var editedTimestamp: Date?
    public var attachments: [Attachment]?
    public var embeds: [Embed]?
    public var reactions: [Reaction]?
    public var pinned: Bool?
    public var type: Int?
    public var referencedMessage: IndirectBox<Message>?
    public var nonce: String?

    /// Public memberwise init so clients can build local placeholder
    /// messages (optimistic sends) without a decoding round trip.
    public init(
        id: Snowflake,
        channelId: Snowflake,
        guildId: Snowflake? = nil,
        author: User? = nil,
        content: String? = nil,
        timestamp: Date? = nil,
        editedTimestamp: Date? = nil,
        attachments: [Attachment]? = nil,
        embeds: [Embed]? = nil,
        reactions: [Reaction]? = nil,
        pinned: Bool? = nil,
        type: Int? = nil,
        referencedMessage: IndirectBox<Message>? = nil,
        nonce: String? = nil
    ) {
        self.id = id
        self.channelId = channelId
        self.guildId = guildId
        self.author = author
        self.content = content
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.attachments = attachments
        self.embeds = embeds
        self.reactions = reactions
        self.pinned = pinned
        self.type = type
        self.referencedMessage = referencedMessage
        self.nonce = nonce
    }
}

/// Boxes a value so a struct can hold a field of its own type.
public struct IndirectBox<Wrapped: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    private final class Storage: @unchecked Sendable {
        let value: Wrapped
        init(_ value: Wrapped) { self.value = value }
    }

    private let storage: Storage

    public init(_ value: Wrapped) {
        self.storage = Storage(value)
    }

    public var value: Wrapped { storage.value }

    public init(from decoder: Decoder) throws {
        self.init(try Wrapped(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    public static func == (lhs: IndirectBox, rhs: IndirectBox) -> Bool {
        lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}
