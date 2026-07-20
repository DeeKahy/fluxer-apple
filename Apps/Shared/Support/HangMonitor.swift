import Foundation
import os
#if os(iOS)
@preconcurrency import MetricKit
#endif

/// Watches for main-thread hangs and stores the evidence where it can be
/// pulled off the device later, so "it froze again" comes with data.
///
/// Two layers:
/// - A live watchdog pings the main queue four times a second and appends
///   a line to Documents/hang-log.txt whenever the response takes longer
///   than the threshold, so every freeze gets a timestamp and duration.
/// - MetricKit hang diagnostics (iOS only) carry real stack traces; each
///   payload lands in Documents/hang-diagnostics-<unixtime>.json.
///
/// Pull the files off a dev-installed build with:
///   xcrun devicectl device copy from --device <uuid> \
///     --domain-type appDataContainer --domain-identifier dev.deekahy.fluxer \
///     --source Documents/hang-log.txt --destination .
final class HangMonitor: NSObject, @unchecked Sendable {
    static let shared = HangMonitor()

    /// Main-queue delay that counts as a hang.
    private static let threshold: TimeInterval = 0.4

    private let queue = DispatchQueue(label: "dev.deekahy.fluxer.hang-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// A ping is in flight; no new one is sent until it returns, so one
    /// hang produces one record with its full duration. Only touched on
    /// the monitor queue.
    private var awaitingPong = false
    private let log = Logger(subsystem: "dev.deekahy.fluxer", category: "hangs")

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var logURL: URL {
        documentsURL.appendingPathComponent("hang-log.txt")
    }

    func start() {
        #if os(iOS)
        MXMetricManager.shared.add(self)
        #endif
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: .milliseconds(250))
            source.setEventHandler { [weak self] in self?.ping() }
            source.resume()
            timer = source
            appendLine("started \(Self.timestamp())")
        }
    }

    private func ping() {
        guard !awaitingPong else { return }
        awaitingPong = true
        let sent = DispatchTime.now()
        DispatchQueue.main.async { [self] in
            queue.async { [self] in
                awaitingPong = false
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000_000
                if seconds > Self.threshold {
                    let line = "\(Self.timestamp()) hang \(Int(seconds * 1000))ms"
                    appendLine(line)
                    log.error("main thread hang: \(Int(seconds * 1000))ms")
                }
            }
        }
    }

    /// Appends to the log file, resetting it if it has grown absurd.
    /// Runs on the monitor queue.
    private func appendLine(_ line: String) {
        let url = Self.logURL
        let data = Data((line + "\n").utf8)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func timestamp() -> String {
        Date().formatted(.iso8601.timeZone(separator: .omitted).time(includingFractionalSeconds: false))
    }
}

#if os(iOS)
extension HangMonitor: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guard let hangs = payload.hangDiagnostics, !hangs.isEmpty else { continue }
            let url = Self.documentsURL
                .appendingPathComponent("hang-diagnostics-\(Int(Date().timeIntervalSince1970)).json")
            try? payload.jsonRepresentation().write(to: url)
            queue.async { [self] in
                appendLine("\(Self.timestamp()) metrickit delivered \(hangs.count) hang diagnostic(s)")
            }
        }
    }
}
#endif
