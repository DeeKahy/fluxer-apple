import Foundation
import Testing
@testable import FluxerKit

@Suite("Snowflake")
struct SnowflakeTests {
    @Test func decodesFromJSONString() throws {
        let data = Data("\"175928847299117063\"".utf8)
        let id = try JSONDecoder().decode(Snowflake.self, from: data)
        #expect(id.rawValue == 175928847299117063)
        #expect(id.stringValue == "175928847299117063")
    }

    @Test func encodesAsString() throws {
        let data = try JSONEncoder().encode(Snowflake(42))
        #expect(String(data: data, encoding: .utf8) == "\"42\"")
    }

    @Test func rejectsGarbage() {
        let data = Data("\"not-a-number\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Snowflake.self, from: data)
        }
    }

    @Test func ordersByValue() {
        #expect(Snowflake(1) < Snowflake(2))
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsNestedStructures() throws {
        let json = """
        {"a": 1, "b": "two", "c": [true, null, 3.5], "d": {"nested": "yes"}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.stringValue == "two")
        #expect(value["c"]?.arrayValue?.count == 3)
        #expect(value["d"]?["nested"]?.stringValue == "yes")

        let reencoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(decoded == value)
    }

    @Test func decodesIntoTypedModel() throws {
        let value = JSONValue.object([
            "id": .string("123"),
            "username": .string("dee"),
        ])
        let user = try value.decoded(as: User.self)
        #expect(user.id == Snowflake(123))
        #expect(user.username == "dee")
    }
}

@Suite("Message decoding")
struct MessageDecodingTests {
    @Test func decodesTypicalMessagePayload() throws {
        let json = """
        {
          "id": "1001",
          "channel_id": "2002",
          "author": {"id": "3003", "username": "dee", "global_name": "Dee"},
          "content": "hello world",
          "timestamp": "2026-07-16T12:00:00Z",
          "attachments": [
            {"id": "4004", "filename": "cat.png", "size": 1234, "content_type": "image/png"}
          ],
          "some_future_field": {"ignored": true}
        }
        """
        let message = try JSONDecoder.fluxer.decode(Message.self, from: Data(json.utf8))
        #expect(message.id == Snowflake(1001))
        #expect(message.channelId == Snowflake(2002))
        #expect(message.author?.displayName == "Dee")
        #expect(message.content == "hello world")
        #expect(message.attachments?.first?.filename == "cat.png")
        #expect(message.timestamp != nil)
    }

    @Test func decodesChannelWithUnknownType() throws {
        let json = """
        {"id": "1", "type": 99, "name": "mystery"}
        """
        let channel = try JSONDecoder.fluxer.decode(Channel.self, from: Data(json.utf8))
        #expect(channel.type == .unknown)
        #expect(channel.name == "mystery")
    }
}
