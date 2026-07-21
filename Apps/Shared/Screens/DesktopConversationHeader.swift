import SwiftUI
import FluxerKit

struct DesktopConversationHeader: View {
    @Environment(AppSession.self) private var session

    let channel: Channel?
    let membersOpen: Bool
    let onPins: () -> Void
    let onToggleMembers: () -> Void

    private var isDM: Bool {
        channel?.type == .dm || channel?.type == .groupDM
    }

    private var dmUser: User? {
        (channel?.recipients ?? []).first { $0.id != session.currentUser?.id }
            ?? channel?.recipients?.first
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if let channel {
                    if isDM {
                        AvatarView(user: dmUser, diameter: 26)
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .fill(Theme.presenceColor(session.presenceStatus(for: dmUser?.id)))
                                    .frame(width: 9, height: 9)
                                    .overlay { Circle().strokeBorder(Theme.deskBg, lineWidth: 2) }
                                    .offset(x: 2, y: 2)
                            }
                    } else if channel.type == .guildVoice {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                    } else {
                        Text("#")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.muted)
                    }
                    Text(title(channel))
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let subtitle {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 2)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                if let channel, isDM {
                    headerButton("phone", help: "Start call") {
                        Task { await session.startCall(in: channel) }
                    }
                    .disabled(session.voice.connectedChannelId == channel.id)
                }
                if let channel, channel.type == .guildVoice,
                   session.voice.connectedChannelId != channel.id {
                    headerButton("phone", help: "Join voice", tint: Theme.green) {
                        Task { await session.joinVoice(channel) }
                    }
                }
                if channel != nil {
                    headerButton("pin", help: "Pinned messages", action: onPins)
                }
                if let channel, channel.guildId != nil,
                   session.permissions(in: channel).contains(.viewChannelMembers) {
                    headerButton(
                        "person.2",
                        help: "Members",
                        tint: membersOpen ? Theme.accentSoft : Theme.icon,
                        action: onToggleMembers
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
    }

    private func title(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        let joined = others.map(\.displayName).joined(separator: ", ")
        return joined.isEmpty ? "Conversation" : joined
    }

    private var subtitle: String? {
        guard let channel else { return nil }
        if isDM {
            let status = session.presenceStatus(for: dmUser?.id)
            switch status {
            case "online": return "Active now"
            case "idle": return "Away"
            case "dnd": return "Do not disturb"
            default: return "Offline"
            }
        }
        if let topic = channel.topic, !topic.isEmpty { return topic }
        return nil
    }

    private func headerButton(
        _ icon: String,
        help: String,
        tint: Color = Theme.icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SquishButtonStyle())
        .help(help)
    }
}
