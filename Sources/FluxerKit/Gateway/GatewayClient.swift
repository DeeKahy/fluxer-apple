import Foundation

public enum GatewayError: Error, Sendable {
    case notConnected
    case invalidPayload(String)
    case sessionInvalidated(resumable: Bool)
}

public enum GatewayState: Sendable, Equatable {
    case disconnected
    case connecting
    case identifying
    case ready
    case resuming
}

/// Maintains the websocket connection to a Fluxer gateway: hello and identify,
/// the heartbeat loop, sequence tracking, and resume state. Consumers read
/// dispatched events from the `events` stream.
public actor GatewayClient {
    public static let defaultGatewayURL = URL(string: "wss://gateway.fluxer.app/?v=1&encoding=json")!

    private let transport: any GatewayTransport
    private let gatewayURL: URL
    private var token: String?

    private(set) public var state: GatewayState = .disconnected
    private var sequence: Int?
    private var sessionId: String?
    private var resumeGatewayURL: URL?
    private var awaitingHeartbeatAck = false

    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?

    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?

    public init(
        transport: any GatewayTransport = URLSessionGatewayTransport(),
        gatewayURL: URL = GatewayClient.defaultGatewayURL
    ) {
        self.transport = transport
        self.gatewayURL = gatewayURL
    }

    /// Stream of dispatched events. Create the stream before calling connect.
    public func events() -> AsyncStream<GatewayEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    public func connect(token: String) async throws {
        self.token = token
        state = .connecting
        let url = resumeGatewayURL ?? gatewayURL
        try await transport.connect(to: url)
        startReceiveLoop()
    }

    /// Asks to join, move, or leave voice. A nil channel leaves. Pass the
    /// connection id from VOICE_SERVER_UPDATE when updating an existing
    /// connection (mute changes); without it the server treats the payload
    /// as a brand new join.
    public func updateVoiceState(
        guildId: Snowflake?,
        channelId: Snowflake?,
        selfMute: Bool = false,
        selfDeaf: Bool = false,
        connectionId: String? = nil
    ) async {
        let payload = GatewayPayload(
            op: .voiceStateUpdate,
            d: .object([
                "guild_id": guildId.map { JSONValue.string($0.stringValue) } ?? .null,
                "channel_id": channelId.map { JSONValue.string($0.stringValue) } ?? .null,
                "self_mute": .bool(selfMute),
                "self_deaf": .bool(selfDeaf),
                "connection_id": connectionId.map(JSONValue.string) ?? .null,
            ])
        )
        await send(payload)
    }

    /// Announces the user's own status: online, idle, dnd, or invisible.
    public func updatePresence(status: String) async {
        let payload = GatewayPayload(
            op: .presenceUpdate,
            d: .object([
                "status": .string(status),
                "since": .number(0),
                "activities": .array([]),
                "afk": .bool(false),
            ])
        )
        await send(payload)
    }

    public func disconnect() async {
        receiveLoop?.cancel()
        heartbeatLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop = nil
        await transport.close()
        state = .disconnected
        eventContinuation?.finish()
    }

    // MARK: Incoming payloads

    private func startReceiveLoop() {
        receiveLoop?.cancel()
        receiveLoop = Task {
            while !Task.isCancelled {
                do {
                    let text = try await transport.receive()
                    await handleIncoming(text: text)
                } catch {
                    await handleDisconnect()
                    break
                }
            }
        }
    }

    func handleIncoming(text: String) async {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GatewayPayload.self, from: data)
        else {
            return
        }
        if let s = payload.s {
            sequence = s
        }
        switch payload.op {
        case .hello:
            let intervalMs = payload.d?["heartbeat_interval"]?.numberValue ?? 41250
            startHeartbeat(interval: intervalMs / 1000)
            if sessionId != nil {
                await sendResume()
            } else {
                await sendIdentify()
            }
        case .heartbeat:
            await sendHeartbeat()
        case .heartbeatAck:
            awaitingHeartbeatAck = false
        case .dispatch:
            handleDispatch(payload)
        case .reconnect:
            await handleDisconnect()
        case .invalidSession:
            let resumable = payload.d?.boolValue ?? false
            if !resumable {
                sessionId = nil
                resumeGatewayURL = nil
                sequence = nil
            }
            await handleDisconnect()
        default:
            break
        }
    }

    private func handleDispatch(_ payload: GatewayPayload) {
        guard let name = payload.t else { return }
        if name == "READY" {
            state = .ready
            sessionId = payload.d?["session_id"]?.stringValue
            if let resumeURL = payload.d?["resume_gateway_url"]?.stringValue {
                resumeGatewayURL = URL(string: resumeURL + "/?v=1&encoding=json") ?? URL(string: resumeURL)
            }
        }
        if name == "RESUMED" {
            state = .ready
        }
        eventContinuation?.yield(GatewayEvent(name: name, data: payload.d, sequence: payload.s))
    }

    // MARK: Outgoing payloads

    private func sendIdentify() async {
        guard let token else { return }
        state = .identifying
        let payload = GatewayPayload(
            op: .identify,
            d: .object([
                "token": .string(token),
                "properties": .object([
                    "os": .string(osName()),
                    "browser": .string("FluxerApple"),
                    "device": .string("FluxerApple"),
                ]),
            ])
        )
        await send(payload)
    }

    private func sendResume() async {
        guard let token, let sessionId else { return }
        state = .resuming
        let payload = GatewayPayload(
            op: .resume,
            d: .object([
                "token": .string(token),
                "session_id": .string(sessionId),
                "seq": sequence.map { JSONValue.number(Double($0)) } ?? .null,
            ])
        )
        await send(payload)
    }

    private func sendHeartbeat() async {
        let payload = GatewayPayload(
            op: .heartbeat,
            d: sequence.map { JSONValue.number(Double($0)) } ?? .null
        )
        awaitingHeartbeatAck = true
        await send(payload)
    }

    private func startHeartbeat(interval: TimeInterval) {
        heartbeatLoop?.cancel()
        awaitingHeartbeatAck = false
        heartbeatLoop = Task {
            // Stagger the first beat so reconnecting clients do not thundering-herd.
            let initialDelay = interval * Double.random(in: 0...1)
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                if self.heartbeatMissed() {
                    await self.handleDisconnect()
                    break
                }
                await self.sendHeartbeat()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func heartbeatMissed() -> Bool {
        awaitingHeartbeatAck
    }

    private func send(_ payload: GatewayPayload) async {
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        try? await transport.send(text: text)
    }

    private func handleDisconnect() async {
        heartbeatLoop?.cancel()
        heartbeatLoop = nil
        await transport.close()
        let wasDisconnected = state == .disconnected
        state = .disconnected
        // Reconnection with backoff is driven by the app layer, which
        // learns about the drop through this synthetic event.
        if !wasDisconnected {
            eventContinuation?.yield(
                GatewayEvent(name: GatewayEvent.disconnected, data: nil, sequence: nil)
            )
        }
    }

    private func osName() -> String {
        #if os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }
}
