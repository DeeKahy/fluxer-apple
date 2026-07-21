import SwiftUI
import FluxerKit

#if os(macOS)
/// Menu bar dropdown: status at a glance and quick controls while the
/// main window is closed.
struct MenuBarContent: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unreadDMs = session.privateChannels.filter { session.isUnread($0) }

        if session.phase == .loggedIn {
            Text(session.gatewayConnected ? "Connected" : "Reconnecting")
            if unreadDMs.isEmpty {
                Text("No unread conversations")
            } else {
                ForEach(unreadDMs.prefix(5)) { channel in
                    Button(dmName(channel)) {
                        session.channelJump = channel
                        openMainWindow()
                    }
                }
            }
        } else {
            Text("Not signed in")
        }

        Divider()

        if session.voice.isActive {
            Button(session.voice.muted ? "Unmute" : "Mute") {
                Task { await session.voice.toggleMute() }
            }
            Button("Leave voice") {
                Task { await session.voice.leave() }
            }
            Divider()
        }

        Button("Open Fluxer") {
            openMainWindow()
        }
        .keyboardShortcut("o")
        Button("Quit Fluxer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func dmName(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }
}
#endif

@main
struct FluxerApp: App {
    @State private var session = AppSession()

    init() {
        NotificationManager.shared.setUp()
        HangMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(session)
                .task {
                    NotificationManager.shared.onOpenChannel = { [weak session] channelId in
                        guard let session else { return }
                        if let channel = session.findChannel(channelId) {
                            session.channelJump = channel
                        }
                    }
                }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .windowStyle(.automatic)
        #endif

        #if os(macOS)
        MenuBarExtra {
            MenuBarContent()
                .environment(session)
        } label: {
            let unread = session.privateChannels.filter { session.isUnread($0) }.count
            if unread > 0 {
                Label("\(unread)", systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill")
            }
        }
        #endif
    }
}
