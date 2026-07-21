import Foundation
import Testing
@testable import FluxerKit

// One decode test per gateway event type the app handles, each using a
// payload shaped like the live server's dispatches (issue #31). If an
// upstream field changes shape these fail in CI instead of as a broken
// screen. Every test pulls fields exactly the way AppSession's gateway
// handler does: snowflake helpers for ids, decoded(as:) for models.

private func eventData(_ json: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

@Suite("Gateway event decoding: READY")
struct ReadyDecodeTests {
    static let readyJSON = """
    {
      "session_id": "abc123session",
      "resume_gateway_url": "wss://gateway.fluxer.app",
      "user": {"id": "100", "username": "dee", "global_name": "Dee", "email": "d@example.net"},
      "guilds": [
        {
          "id": "200",
          "properties": {"id": "200", "name": "Fluxer HQ", "icon": "a1b2c3", "owner_id": "100"},
          "channels": [
            {"id": "210", "type": 0, "name": "general", "position": 0, "last_message_id": "9000"},
            {"id": "211", "type": 2, "name": "voice lounge", "position": 1},
            {"id": "212", "type": 4, "name": "chat", "position": 2}
          ],
          "roles": [{"id": "200", "name": "@everyone", "permissions": "104324673", "position": 0}],
          "emojis": [{"id": "290", "name": "blob"}],
          "members": [{"user": {"id": "100", "username": "dee"}, "roles": []}],
          "voice_states": [
            {"user_id": "300", "channel_id": "211", "self_mute": true, "self_deaf": false, "mute": false, "deaf": false}
          ],
          "member_count": 42,
          "presences": [{"user": {"id": "300"}, "status": "online"}]
        }
      ],
      "private_channels": [
        {"id": "400", "type": 1, "recipients": [{"id": "300", "username": "friend"}], "last_message_id": "8000"}
      ],
      "read_states": [
        {"id": "210", "last_message_id": "8999", "mention_count": 2},
        {"id": "400", "last_message_id": "8000"}
      ],
      "users": [{"id": "300", "username": "friend", "global_name": "Friend"}],
      "relationships": [
        {"id": "300", "type": 1, "user": {"id": "300", "username": "friend"}, "since": "2026-07-01T00:00:00Z"}
      ],
      "pinned_dms": ["400"],
      "presences": [{"user_id": "300", "status": "idle"}]
    }
    """

    @Test func decodesEveryReadySection() throws {
        let data = eventData(Self.readyJSON)

        let user = try data["user"]?.decoded(as: User.self)
        #expect(user?.id == Snowflake(100))

        let guild = try data["guilds"]?.arrayValue?.first?.decoded(as: ReadyGuild.self)
        let flattened = try #require(guild).asGuild()
        #expect(flattened.name == "Fluxer HQ")
        #expect(flattened.channels?.count == 3)
        #expect(flattened.channels?.first?.lastMessageId == Snowflake(9000))
        #expect(flattened.roles?.first?.name == "@everyone")
        #expect(flattened.emojis?.first?.id == Snowflake(290))
        #expect(flattened.memberCount == 42)

        let voiceState = try data["guilds"]?.arrayValue?.first?["voice_states"]?
            .arrayValue?.first?.decoded(as: VoiceState.self)
        #expect(voiceState?.userId == Snowflake(300))
        #expect(voiceState?.channelId == Snowflake(211))
        #expect(voiceState?.isMuted == true)

        let dm = try data["private_channels"]?.arrayValue?.first?.decoded(as: Channel.self)
        #expect(dm?.type == .dm)
        #expect(dm?.recipients?.first?.username == "friend")

        let readState = try data["read_states"]?.arrayValue?.first?.decoded(as: ReadState.self)
        #expect(readState?.id == Snowflake(210))
        #expect(readState?.lastMessageId == Snowflake(8999))
        #expect(readState?.mentionCount == 2)

        let relationship = try data["relationships"]?.arrayValue?.first?.decoded(as: Relationship.self)
        #expect(relationship?.type == .friend)
        #expect(relationship?.user?.id == Snowflake(300))

        let pinned = (data["pinned_dms"]?.arrayValue ?? []).compactMap {
            $0.stringValue.flatMap(Snowflake.init(string:))
        }
        #expect(pinned == [Snowflake(400)])
    }

    @Test func presencesCarryBothIdShapes() {
        let data = eventData(Self.readyJSON)
        // Top level entries use user_id, per guild entries use user.id;
        // applyPresence reads whichever is present.
        let topLevel = data["presences"]?.arrayValue?.first
        #expect(topLevel?["user"]?.snowflake("id") ?? topLevel?.snowflake("user_id") == Snowflake(300))
        #expect(topLevel?["status"]?.stringValue == "idle")
        let perGuild = data["guilds"]?.arrayValue?.first?["presences"]?.arrayValue?.first
        #expect(perGuild?["user"]?.snowflake("id") ?? perGuild?.snowflake("user_id") == Snowflake(300))
        #expect(perGuild?["status"]?.stringValue == "online")
    }

    @Test func oneBadGuildEntryStillDecodesTheRest() {
        // The handler decodes guilds one by one so a single malformed
        // entry cannot take down login.
        let data = eventData("""
        {"guilds": [
            {"id": "1", "properties": null},
            {"id": "2", "properties": {"id": "2", "name": "Survivor"}}
        ]}
        """)
        var decoded: [ReadyGuild] = []
        for entry in data["guilds"]?.arrayValue ?? [] {
            if let guild = try? entry.decoded(as: ReadyGuild.self) {
                decoded.append(guild)
            }
        }
        #expect(decoded.count == 1)
        #expect(decoded.first?.asGuild().name == "Survivor")
    }
}

@Suite("Gateway event decoding: messages")
struct MessageEventDecodeTests {
    @Test func messageCreateWithMentionsReplyAndNonce() throws {
        // A full envelope as it comes off the socket.
        let payload = try JSONDecoder().decode(GatewayPayload.self, from: Data("""
        {"op": 0, "s": 12, "t": "MESSAGE_CREATE", "d": {
          "id": "9001",
          "channel_id": "210",
          "guild_id": "200",
          "author": {"id": "300", "username": "friend"},
          "content": "hey <@100> look",
          "timestamp": "2026-07-20T14:30:00Z",
          "mentions": [{"id": "100", "username": "dee"}],
          "mention_everyone": false,
          "nonce": "17421890571",
          "referenced_message": {
            "id": "8999",
            "channel_id": "210",
            "author": {"id": "100", "username": "dee"},
            "content": "original"
          },
          "attachments": [],
          "embeds": []
        }}
        """.utf8))
        #expect(payload.t == "MESSAGE_CREATE")
        let message = try #require(payload.d).decoded(as: Message.self)
        #expect(message.id == Snowflake(9001))
        #expect(message.nonce == "17421890571")
        #expect(message.timestamp != nil)
        #expect(message.referencedMessage?.value.content == "original")
        // The notification path reads mentions from the raw payload.
        let mentioned = (payload.d?["mentions"]?.arrayValue ?? []).contains {
            $0["id"]?.stringValue == "100"
        }
        #expect(mentioned)
    }

    @Test func messageUpdateCarriesEditTimestamp() throws {
        let data = eventData("""
        {"id": "9001", "channel_id": "210", "content": "fixed typo",
         "edited_timestamp": "2026-07-20T14:31:00Z"}
        """)
        let message = try data.decoded(as: Message.self)
        #expect(message.editedTimestamp != nil)
        #expect(message.content == "fixed typo")
    }

    @Test func messageDeleteUsesTopLevelIds() {
        let data = eventData("""
        {"id": "9001", "channel_id": "210", "guild_id": "200"}
        """)
        #expect(data.snowflake("id") == Snowflake(9001))
        #expect(data.snowflake("channel_id") == Snowflake(210))
    }

    @Test func messageAckCarriesChannelAndMessage() {
        let data = eventData("""
        {"channel_id": "210", "message_id": "9001", "version": 3}
        """)
        #expect(data.snowflake("channel_id") == Snowflake(210))
        #expect(data.snowflake("message_id") == Snowflake(9001))
    }

    @Test func reactionEventsDecodeUnicodeAndCustomEmoji() throws {
        let unicode = eventData("""
        {"channel_id": "210", "message_id": "9001", "user_id": "300",
         "emoji": {"id": null, "name": "\u{1F44D}"}}
        """)
        let unicodeEmoji = try unicode["emoji"]?.decoded(as: ReactionEmoji.self)
        #expect(unicodeEmoji?.id == nil)
        #expect(unicodeEmoji?.apiValue == "\u{1F44D}")

        let custom = eventData("""
        {"channel_id": "210", "message_id": "9001", "user_id": "300",
         "emoji": {"id": "290", "name": "blob", "animated": true}}
        """)
        let customEmoji = try custom["emoji"]?.decoded(as: ReactionEmoji.self)
        #expect(customEmoji?.apiValue == "blob:290")
        #expect(custom.snowflake("user_id") == Snowflake(300))
    }

    @Test func typingStartCarriesChannelAndUser() {
        let data = eventData("""
        {"channel_id": "210", "user_id": "300", "timestamp": 1752849000}
        """)
        #expect(data.snowflake("channel_id") == Snowflake(210))
        #expect(data.snowflake("user_id") == Snowflake(300))
    }
}

@Suite("Gateway event decoding: channels and guilds")
struct ChannelGuildEventDecodeTests {
    @Test func channelCreateInGuild() throws {
        let channel = try eventData("""
        {"id": "213", "type": 0, "guild_id": "200", "name": "new-stuff",
         "position": 3, "rate_limit_per_user": 30}
        """).decoded(as: Channel.self)
        #expect(channel.guildId == Snowflake(200))
        #expect(channel.type == .guildText)
        #expect(channel.rateLimitPerUser == 30)
    }

    @Test func channelCreateForGroupDM() throws {
        let channel = try eventData("""
        {"id": "401", "type": 3, "name": "the gang",
         "recipients": [{"id": "300", "username": "friend"}, {"id": "301", "username": "pal"}]}
        """).decoded(as: Channel.self)
        #expect(channel.type == .groupDM)
        #expect(channel.recipients?.count == 2)
    }

    @Test func unknownChannelTypeDoesNotThrow() throws {
        let channel = try eventData("""
        {"id": "999", "type": 42, "name": "future thing"}
        """).decoded(as: Channel.self)
        #expect(channel.type == .unknown)
    }

    @Test func guildCreateArrivesWrappedLikeReady() throws {
        let guild = try eventData("""
        {"id": "500",
         "properties": {"id": "500", "name": "Fresh Guild", "owner_id": "300"},
         "channels": [{"id": "510", "type": 0, "name": "general"}],
         "member_count": 1}
        """).decoded(as: ReadyGuild.self)
        #expect(guild.asGuild().name == "Fresh Guild")
        #expect(guild.asGuild().channels?.count == 1)
    }

    @Test func guildDeleteUsesTopLevelId() {
        #expect(eventData("{\"id\": \"500\", \"unavailable\": false}").snowflake("id") == Snowflake(500))
    }
}

@Suite("Gateway event decoding: presence and relationships")
struct SocialEventDecodeTests {
    @Test func presenceUpdateWithNestedUser() {
        let data = eventData("""
        {"user": {"id": "300"}, "status": "dnd", "activities": []}
        """)
        let userId = data["user"]?.snowflake("id") ?? data.snowflake("user_id")
        #expect(userId == Snowflake(300))
        #expect(data["status"]?.stringValue == "dnd")
    }

    @Test func presenceUpdateBulkIsAnArray() {
        let data = eventData("""
        [{"user_id": "300", "status": "online"}, {"user_id": "301", "status": "offline"}]
        """)
        let entries = data.arrayValue ?? []
        #expect(entries.count == 2)
        #expect(entries.last?["status"]?.stringValue == "offline")
    }

    @Test func relationshipAddDecodesTypeAndUser() throws {
        let relationship = try eventData("""
        {"id": "300", "type": 3, "user": {"id": "300", "username": "friend"}, "nickname": null}
        """).decoded(as: Relationship.self)
        #expect(relationship.type == .incomingRequest)
        #expect(relationship.user?.username == "friend")
    }

    @Test func unknownRelationshipTypeDoesNotThrow() throws {
        let relationship = try eventData("""
        {"id": "300", "type": 99}
        """).decoded(as: Relationship.self)
        #expect(relationship.type == .unknown)
    }

    @Test func relationshipRemoveUsesTopLevelId() {
        #expect(eventData("{\"id\": \"300\", \"type\": 1}").snowflake("id") == Snowflake(300))
    }
}

@Suite("Gateway event decoding: voice and calls")
struct VoiceEventDecodeTests {
    @Test func voiceServerUpdateDecodesEndpointAndConnection() throws {
        let update = try eventData("""
        {"token": "lk-token-abc", "endpoint": "livekit.fluxer.app",
         "connection_id": "conn-123", "guild_id": "200", "channel_id": "211",
         "e2ee_key": "secret"}
        """).decoded(as: VoiceServerUpdate.self)
        #expect(update.token == "lk-token-abc")
        #expect(update.connectionId == "conn-123")
        #expect(update.url?.absoluteString == "wss://livekit.fluxer.app")
    }

    @Test func voiceServerUpdateKeepsExplicitScheme() throws {
        let update = try eventData("""
        {"token": "t", "endpoint": "wss://livekit.fluxer.app:443"}
        """).decoded(as: VoiceServerUpdate.self)
        #expect(update.url?.absoluteString == "wss://livekit.fluxer.app:443")
    }

    @Test func voiceStateUpdateSurvivesExtraUpstreamFields() throws {
        // Upstream's default_voice_state_fields carries more than we model;
        // the extras must never break decoding.
        let state = try eventData("""
        {"user_id": "300", "channel_id": "211", "guild_id": "200",
         "session_id": "s1", "self_mute": false, "self_deaf": true,
         "mute": false, "deaf": false, "self_video": true,
         "self_stream": false, "suppress": false}
        """).decoded(as: VoiceState.self)
        #expect(state.selfDeaf == true)
        #expect(state.isMuted == false)
    }

    @Test func voiceLeaveHasNullChannel() throws {
        let state = try eventData("""
        {"user_id": "300", "channel_id": null, "guild_id": "200"}
        """).decoded(as: VoiceState.self)
        #expect(state.channelId == nil)
    }

    @Test func callCreateCarriesRingingListAndVoiceStates() throws {
        let data = eventData("""
        {"channel_id": "400", "message_id": "9100",
         "ringing": ["100"],
         "voice_states": [{"user_id": "300", "channel_id": "400", "self_mute": false}]}
        """)
        #expect(data.snowflake("channel_id") == Snowflake(400))
        let ringing = (data["ringing"]?.arrayValue ?? []).compactMap {
            $0.stringValue.flatMap(Snowflake.init(string:))
        }
        #expect(ringing == [Snowflake(100)])
        let state = try data["voice_states"]?.arrayValue?.first?.decoded(as: VoiceState.self)
        #expect(state?.userId == Snowflake(300))
    }

    @Test func callDeleteUsesChannelId() {
        #expect(eventData("{\"channel_id\": \"400\"}").snowflake("channel_id") == Snowflake(400))
    }
}
