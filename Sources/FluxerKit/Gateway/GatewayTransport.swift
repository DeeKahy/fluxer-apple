import Foundation

/// Abstraction over the websocket so GatewayClient can be tested with a fake.
public protocol GatewayTransport: Sendable {
    func connect(to url: URL) async throws
    func send(text: String) async throws
    /// Waits for and returns the next text frame. Throws when the socket closes or fails.
    func receive() async throws -> String
    func close() async
}

/// Production transport backed by URLSessionWebSocketTask.
public final class URLSessionGatewayTransport: GatewayTransport, @unchecked Sendable {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        setTask(task)
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task = currentTask() else {
            throw URLError(.networkConnectionLost)
        }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task = currentTask() else {
            throw URLError(.networkConnectionLost)
        }
        while true {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    return text
                }
            @unknown default:
                continue
            }
        }
    }

    public func close() async {
        let task = takeTask()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func setTask(_ task: URLSessionWebSocketTask?) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func takeTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        let current = task
        task = nil
        return current
    }
}
