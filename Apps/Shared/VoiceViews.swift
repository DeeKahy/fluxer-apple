import SwiftUI
import FluxerKit

/// Bottom bar shown while voice is active anywhere in the app.
struct VoiceBar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if session.voice.isActive {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(phaseColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channelName)
                        .font(.callout.bold())
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await session.voice.toggleMute() }
                } label: {
                    Image(systemName: session.voice.muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(session.voice.muted ? .red : .primary)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await session.voice.leave() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }

    private var channelName: String {
        guard let channelId = session.voice.connectedChannelId,
              let channel = session.findChannel(channelId)
        else { return "Voice" }
        if let name = channel.name, !name.isEmpty {
            return name
        }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }

    private var statusText: String {
        switch session.voice.phase {
        case .idle: return ""
        case .requesting, .connecting: return "Connecting"
        case .connected:
            let count = session.voice.roomParticipantIds.count
            return count == 1 ? "Connected, just you" : "Connected, \(count) in voice"
        }
    }

    private var phaseColor: Color {
        if case .connected = session.voice.phase { return .green }
        return .orange
    }
}

/// A voice channel row: occupants listed under the name, tap to join.
struct VoiceChannelRow: View {
    @Environment(AppSession.self) private var session

    let channel: Channel

    private var occupants: [Snowflake] {
        Array(session.voiceChannelUsers[channel.id] ?? [])
    }

    var body: some View {
        Button {
            Task { await session.joinVoice(channel) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(channel.name ?? "voice", systemImage: "speaker.wave.2")
                    Spacer()
                    if session.voice.connectedChannelId == channel.id {
                        Image(systemName: "waveform")
                            .foregroundStyle(.green)
                    } else if !occupants.isEmpty {
                        Text("\(occupants.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !occupants.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(occupants.prefix(6), id: \.self) { userId in
                            let user = session.knownUsers[userId]
                            AvatarView(user: user, diameter: 20)
                                .overlay {
                                    if session.voice.speakingUserIds.contains(userId) {
                                        Circle().strokeBorder(.green, lineWidth: 2)
                                    }
                                }
                        }
                        if occupants.count > 6 {
                            Text("+\(occupants.count - 6)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
