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
}
