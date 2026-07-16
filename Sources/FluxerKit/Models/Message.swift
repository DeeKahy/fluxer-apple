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

public struct Message: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var channelId: Snowflake
    public var guildId: Snowflake?
    public var author: User?
    public var content: String?
    public var timestamp: Date?
    public var editedTimestamp: Date?
    public var attachments: [Attachment]?
    public var pinned: Bool?
    public var type: Int?
    public var referencedMessage: IndirectBox<Message>?
    public var nonce: String?
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
