import Foundation
import Testing
@testable import FluxerKit

/// In-memory transport that records outgoing frames and lets tests feed incoming ones.
actor FakeTransport: GatewayTransport {
    private(set) var sentFrames: [String] = []
    private(set) var connectedURL: URL?
    private(set) var closed = false

    private var pending: [String] = []
    private var waiters: [CheckedContinuation<String, any Error>] = []

    func connect(to url: URL) async throws {
        connectedURL = url
    }

    func send(text: String) async throws {
        sentFrames.append(text)
    }

    func receive() async throws -> String {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        closed = true
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
        waiters.removeAll()
    }

    func feed(_ text: String) {
        if waiters.isEmpty {
            pending.append(text)
        } else {
            waiters.removeFirst().resume(returning: text)
        }
    }

    func sentPayloads() throws -> [GatewayPayload] {
        try sentFrames.map {
            try JSONDecoder().decode(GatewayPayload.self, from: Data($0.utf8))
        }
    }
}

@Suite("GatewayPayload")
struct GatewayPayloadTests {
    @Test func decodesHello() throws {
        let json = """
        {"op": 10, "d": {"heartbeat_interval": 41250}}
        """
        let payload = try JSONDecoder().decode(GatewayPayload.self, from: Data(json.utf8))
        #expect(payload.op == .hello)
        #expect(payload.d?["heartbeat_interval"]?.numberValue == 41250)
    }

    @Test func decodesDispatchWithSequenceAndName() throws {
        let json = """
        {"op": 0, "t": "MESSAGE_CREATE", "s": 7, "d": {"id": "1", "channel_id": "2"}}
        """
        let payload = try JSONDecoder().decode(GatewayPayload.self, from: Data(json.utf8))
        #expect(payload.op == .dispatch)
        #expect(payload.t == "MESSAGE_CREATE")
        #expect(payload.s == 7)
    }
}

@Suite("ReadyPayload")
struct ReadyPayloadTests {
    @Test func decodesWrappedGuilds() throws {
        let json = """
        {
          "session_id": "sess1",
          "resume_gateway_url": "wss://resume.test",
          "user": {"id": "1", "username": "dee"},
          "guilds": [
            {
              "id": "10",
              "properties": {"id": "10", "name": "My Guild", "owner_id": "1"},
              "channels": [
                {"id": "11", "type": 0, "guild_id": "10", "name": "general", "position": 0},
                {"id": "12", "type": 4, "guild_id": "10", "name": "Category", "position": 1}
              ],
              "member_count": 5,
              "roles": [],
              "joined_at": "2026-01-01T00:00:00Z"
            }
          ],
          "private_channels": [
            {"id": "20", "type": 1, "recipients": [{"id": "2", "username": "friend"}]}
          ]
        }
        """
        let ready = try JSONDecoder.fluxer.decode(ReadyPayload.self, from: Data(json.utf8))
        #expect(ready.sessionId == "sess1")
        #expect(ready.user.username == "dee")

        let guild = try #require(ready.guilds.first?.asGuild())
        #expect(guild.name == "My Guild")
        #expect(guild.memberCount == 5)
        #expect(guild.channels?.count == 2)
        #expect(guild.channels?.first?.name == "general")

        #expect(ready.privateChannels?.first?.type == .dm)
        #expect(ready.privateChannels?.first?.recipients?.first?.username == "friend")
    }
}

@Suite("GatewayClient")
struct GatewayClientTests {
    private func makeClient() -> (GatewayClient, FakeTransport) {
        let transport = FakeTransport()
        let client = GatewayClient(
            transport: transport,
            gatewayURL: URL(string: "wss://gateway.test/?v=1&encoding=json")!
        )
        return (client, transport)
    }

    private func waitForFrames(
        _ transport: FakeTransport,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws -> [GatewayPayload] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let payloads = try await transport.sentPayloads()
            if payloads.count >= count {
                return payloads
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await transport.sentPayloads()
    }

    @Test func identifiesAfterHello() async throws {
        let (client, transport) = makeClient()
        try await client.connect(token: "tok123")
        await transport.feed("""
        {"op": 10, "d": {"heartbeat_interval": 45000}}
        """)

        let payloads = try await waitForFrames(transport, count: 1)
        let identify = try #require(payloads.first(where: { $0.op == .identify }))
        #expect(identify.d?["token"]?.stringValue == "tok123")
        #expect(identify.d?["properties"]?["browser"]?.stringValue == "FluxerApple")
    }

    @Test func respondsToServerHeartbeatRequest() async throws {
        let (client, transport) = makeClient()
        try await client.connect(token: "tok")
        await transport.feed("""
        {"op": 10, "d": {"heartbeat_interval": 45000}}
        """)
        _ = try await waitForFrames(transport, count: 1)

        await transport.feed("""
        {"op": 1, "d": null}
        """)
        let payloads = try await waitForFrames(transport, count: 2)
        #expect(payloads.contains(where: { $0.op == .heartbeat }))
    }

    @Test func dispatchesEventsToStream() async throws {
        let (client, transport) = makeClient()
        let events = await client.events()
        try await client.connect(token: "tok")
        await transport.feed("""
        {"op": 10, "d": {"heartbeat_interval": 45000}}
        """)
        await transport.feed("""
        {"op": 0, "t": "MESSAGE_CREATE", "s": 1, "d": {"id": "9", "channel_id": "8", "content": "hi"}}
        """)

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.name == "MESSAGE_CREATE")
        let message = try #require(try event?.data?.decoded(as: Message.self))
        #expect(message.content == "hi")
    }

    @Test func becomesReadyAndStoresSession() async throws {
        let (client, transport) = makeClient()
        let events = await client.events()
        try await client.connect(token: "tok")
        await transport.feed("""
        {"op": 10, "d": {"heartbeat_interval": 45000}}
        """)
        await transport.feed("""
        {"op": 0, "t": "READY", "s": 1, "d": {"session_id": "abc", "resume_gateway_url": "wss://resume.test", "user": {"id": "1", "username": "dee"}}}
        """)

        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        let state = await client.state
        #expect(state == .ready)
    }

    @Test func heartbeatCarriesLastSequence() async throws {
        let (client, transport) = makeClient()
        let events = await client.events()
        try await client.connect(token: "tok")
        await transport.feed("""
        {"op": 10, "d": {"heartbeat_interval": 45000}}
        """)
        await transport.feed("""
        {"op": 0, "t": "READY", "s": 5, "d": {"session_id": "abc"}}
        """)
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()

        await transport.feed("""
        {"op": 1, "d": null}
        """)
        let payloads = try await waitForFrames(transport, count: 2)
        let heartbeat = try #require(payloads.last(where: { $0.op == .heartbeat }))
        #expect(heartbeat.d?.numberValue == 5)
    }

    @Test func voiceStateUpdateCarriesMuteAndConnectionId() async throws {
        let (client, transport) = makeClient()
        try await client.connect(token: "tok")
        await client.updateVoiceState(
            guildId: Snowflake(10),
            channelId: Snowflake(11),
            selfMute: true,
            connectionId: "conn-1"
        )

        let payloads = try await waitForFrames(transport, count: 1)
        let update = try #require(payloads.first(where: { $0.op == .voiceStateUpdate }))
        #expect(update.d?["guild_id"]?.stringValue == "10")
        #expect(update.d?["channel_id"]?.stringValue == "11")
        #expect(update.d?["self_mute"]?.boolValue == true)
        #expect(update.d?["connection_id"]?.stringValue == "conn-1")
    }

    @Test func voiceStateUpdateWithoutConnectionSendsNull() async throws {
        let (client, transport) = makeClient()
        try await client.connect(token: "tok")
        await client.updateVoiceState(guildId: nil, channelId: Snowflake(11))

        let payloads = try await waitForFrames(transport, count: 1)
        let update = try #require(payloads.first(where: { $0.op == .voiceStateUpdate }))
        #expect(update.d?["guild_id"] == JSONValue.null)
        #expect(update.d?["connection_id"] == JSONValue.null)
        #expect(update.d?["self_mute"]?.boolValue == false)
    }
}

@Suite("VoiceState")
struct VoiceStateTests {
    @Test func decodesMuteFlags() throws {
        let json = """
        {"user_id": "7", "channel_id": "11", "guild_id": "10", "self_mute": true, "self_deaf": false, "mute": false, "deaf": false}
        """
        let state = try JSONDecoder.fluxer.decode(VoiceState.self, from: Data(json.utf8))
        #expect(state.userId == Snowflake(7))
        #expect(state.selfMute == true)
        #expect(state.isMuted)
    }

    @Test func serverMuteCountsAsMuted() throws {
        let json = """
        {"user_id": "7", "channel_id": "11", "self_mute": false, "mute": true}
        """
        let state = try JSONDecoder.fluxer.decode(VoiceState.self, from: Data(json.utf8))
        #expect(state.selfMute == false)
        #expect(state.isMuted)
    }

    @Test func unmutedWhenNoFlagsSet() throws {
        let json = """
        {"user_id": "7", "channel_id": "11"}
        """
        let state = try JSONDecoder.fluxer.decode(VoiceState.self, from: Data(json.utf8))
        #expect(!state.isMuted)
    }
}
