import Foundation
import UserNotifications
import FluxerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Native notifications for DMs, mentions, and incoming calls while the
/// gateway is connected. On the Mac the app keeps running with its window
/// closed, so this covers the app-not-visible case there. True closed-app
/// push on iPhone needs APNs and a relay, tracked in the roadmap.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Set by the app so notification taps can navigate.
    var onOpenChannel: ((Snowflake) -> Void)?

    private var authorized = false

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// True when the app is frontmost, meaning in-app UI already shows it.
    private var appIsActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    func notifyMessage(
        _ message: Message,
        channelTitle: String,
        isDM: Bool,
        mentionsMe: Bool,
        isActiveChannel: Bool
    ) {
        guard authorized, isDM || mentionsMe else { return }
        // Skip when the person is already looking at that conversation.
        if isActiveChannel && appIsActive { return }
        let content = UNMutableNotificationContent()
        let author = message.author?.displayName ?? "Someone"
        content.title = isDM ? author : "\(author) in \(channelTitle)"
        if mentionsMe && !isDM {
            content.subtitle = "Mentioned you"
        }
        content.body = message.content?.isEmpty == false
            ? String((message.content ?? "").prefix(300))
            : "Sent an attachment"
        content.sound = .default
        content.userInfo = ["channelId": message.channelId.stringValue]
        content.threadIdentifier = message.channelId.stringValue
        deliver(content, id: "msg-\(message.id.stringValue)")
    }

    func notifyIncomingCall(from name: String, channelId: Snowflake) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "Incoming call"
        #if os(iOS)
        content.sound = .defaultRingtone
        #else
        content.sound = .default
        #endif
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["channelId": channelId.stringValue]
        deliver(content, id: "call-\(channelId.stringValue)")
    }

    func clearCallNotification(channelId: Snowflake) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["call-\(channelId.stringValue)"])
        center.removePendingNotificationRequests(withIdentifiers: ["call-\(channelId.stringValue)"])
    }

    func updateBadge(unreadCount: Int) {
        guard authorized else { return }
        try? UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is frontmost on the Mac; on iOS the
    /// in-channel check above already filters the noisy case.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let idString = info["channelId"] as? String,
              let channelId = Snowflake(string: idString)
        else { return }
        await MainActor.run {
            NotificationManager.shared.onOpenChannel?(channelId)
        }
    }
}
