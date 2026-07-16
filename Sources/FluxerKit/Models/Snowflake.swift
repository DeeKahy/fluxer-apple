import Foundation

/// A Fluxer object id. The API serialises these as decimal strings inside JSON,
/// so this wraps the string form and keeps the numeric value available.
public struct Snowflake: Hashable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        guard let value = UInt64(string) else { return nil }
        self.rawValue = value
    }

    public var stringValue: String {
        String(rawValue)
    }
}

extension Snowflake: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard let value = UInt64(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Snowflake string is not a valid unsigned integer: \(string)"
                )
            }
            self.rawValue = value
        } else {
            self.rawValue = try container.decode(UInt64.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

extension Snowflake: CustomStringConvertible {
    public var description: String { stringValue }
}

extension Snowflake: Comparable {
    public static func < (lhs: Snowflake, rhs: Snowflake) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
