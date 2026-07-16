import Foundation

/// Gateway opcodes. Fluxer follows the Discord numbering.
public enum GatewayOpcode: Int, Codable, Sendable {
    case dispatch = 0
    case heartbeat = 1
    case identify = 2
    case presenceUpdate = 3
    case voiceStateUpdate = 4
    case resume = 6
    case reconnect = 7
    case invalidSession = 9
    case hello = 10
    case heartbeatAck = 11
}

/// The envelope every gateway message travels in: op, d, s, t.
public struct GatewayPayload: Codable, Sendable {
    public var op: GatewayOpcode
    public var d: JSONValue?
    public var s: Int?
    public var t: String?

    public init(op: GatewayOpcode, d: JSONValue? = nil, s: Int? = nil, t: String? = nil) {
        self.op = op
        self.d = d
        self.s = s
        self.t = t
    }
}

/// A dispatched gateway event, such as MESSAGE_CREATE or READY.
public struct GatewayEvent: Sendable {
    public let name: String
    public let data: JSONValue?
    public let sequence: Int?
}
