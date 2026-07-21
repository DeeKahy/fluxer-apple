import Foundation

/// A general JSON value. Gateway payloads carry arbitrary data in their `d` field,
/// so we decode into this and pick out typed models afterwards.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

extension JSONValue {
    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    public var intValue: Int? {
        guard let number = numberValue, number.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
        return Int(number)
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Reads a snowflake id field out of an object value, accepting both
    /// the usual string form and a bare number. Collapses the
    /// `data?["key"]?.stringValue.flatMap(Snowflake.init(string:))` chains
    /// the gateway handlers were full of.
    public func snowflake(_ key: String) -> Snowflake? {
        switch self[key] {
        case .string(let string):
            return Snowflake(string: string)
        case .number(let number) where number >= 0 && number.truncatingRemainder(dividingBy: 1) == 0:
            return Snowflake(UInt64(number))
        default:
            return nil
        }
    }

    /// Re-encodes this value and decodes it as a concrete model type.
    public func decoded<T: Decodable>(as type: T.Type, decoder: JSONDecoder = .fluxer) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }
}

extension JSONDecoder {
    /// Decoder configured for Fluxer API payloads.
    public static var fluxer: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    /// Encoder configured for Fluxer API payloads.
    public static var fluxer: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
