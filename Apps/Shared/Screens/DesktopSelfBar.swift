import SwiftUI
import FluxerKit

/// The green voice status strip above the self bar: restore the call,
/// toggle screen share on the Mac, hang up.
struct DesktopVoiceConnectedBar: View {
    @Environment(AppSession.self) private var session

    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.green)
            Button(action: onRestore) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice Connected")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.green)
                    Text(voiceChannelName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            Button {
                Task { await session.voice.toggleScreenShare() }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(session.voice.screenSharing ? Theme.accentSoft : Theme.icon)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
            #endif
            Button {
                Task { await session.voice.leave() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.red)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .liquidGlass(tint: Theme.green.opacity(0.35), cornerRadius: 14)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private var voiceChannelName: String {
        guard let channelId = session.voice.connectedChannelId,
              let channel = session.findChannel(channelId)
        else { return "Voice" }
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }

}

/// The account strip at the bottom of the sidebar: avatar with the
/// sessions/logout popover, name, and the four clickable status dots.
struct DesktopSelfBar: View {
    @Environment(AppSession.self) private var session

    @State private var showAccountMenu = false
    @State private var showSessions = false

    var body: some View {
        HStack(spacing: 9) {
            // Not a Menu label: AppKit flattens those to the image's
            // intrinsic size, which blew the avatar up to full resolution.
            Button {
                showAccountMenu = true
            } label: {
                AvatarView(user: session.currentUser, diameter: 32)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Theme.presenceColor(session.myStatus == "invisible" ? nil : session.myStatus))
                            .frame(width: 10, height: 10)
                            .overlay { Circle().strokeBorder(Theme.sidebarBg, lineWidth: 2) }
                            .offset(x: 2, y: 2)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(SquishButtonStyle())
            .popover(isPresented: $showAccountMenu, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        showAccountMenu = false
                        showSessions = true
                    } label: {
                        Label("Sessions", systemImage: "laptopcomputer.and.iphone")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    Button(role: .destructive) {
                        showAccountMenu = false
                        Task { await session.logout() }
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(DeskRowStyle())
                .padding(6)
                .frame(width: 170)
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.currentUser?.displayName ?? "You")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(statusLabel(session.myStatus))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            ForEach(["online", "idle", "dnd", "invisible"], id: \.self) { status in
                Button {
                    Task { await session.setStatus(status) }
                } label: {
                    Circle()
                        .fill(Theme.presenceColor(status == "invisible" ? nil : status))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if session.myStatus == status {
                                Circle().strokeBorder(.white, lineWidth: 2)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(SquishButtonStyle())
                .help(statusLabel(status))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 16)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showSessions) { SessionsView() }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "online": return "Active"
        case "idle": return "Away"
        case "dnd": return "Do not disturb"
        default: return "Invisible"
        }
    }
}
