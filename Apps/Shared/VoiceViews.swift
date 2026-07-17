import SwiftUI
import FluxerKit

/// Bottom bar shown while voice is active anywhere in the app.
struct VoiceBar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if session.voice.isActive {
            HStack(spacing: 12) {
                Image(systemName: session.voice.isRinging ? "phone.arrow.up.right" : "waveform")
                    .foregroundStyle(phaseColor)
                    .symbolEffect(.pulse, isActive: session.voice.isRinging)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channelName)
                        .font(.callout.bold())
                        .lineLimit(1)
                    Text(session.voice.lastError ?? statusText)
                        .font(.caption)
                        .foregroundStyle(session.voice.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                participantStrip
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
            if session.voice.isRinging {
                return "Calling, waiting for an answer"
            }
            let count = session.voice.roomParticipantIds.count
            return count == 1 ? "Connected, just you" : "Connected, \(count) in voice"
        }
    }

    /// Everyone in the room, speaking shown as a green ring.
    @ViewBuilder
    private var participantStrip: some View {
        let ids = session.voice.roomParticipantIds.sorted()
        if !ids.isEmpty {
            HStack(spacing: -6) {
                ForEach(ids.prefix(5), id: \.self) { userId in
                    AvatarView(user: participantUser(userId), diameter: 26)
                        .overlay {
                            Circle().strokeBorder(
                                session.voice.speakingUserIds.contains(userId) ? Color.green : Color.clear,
                                lineWidth: 2.5
                            )
                        }
                        .background(Circle().fill(.background))
                }
                if ids.count > 5 {
                    Text("+\(ids.count - 5)")
                        .font(.caption2)
                        .padding(.leading, 10)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func participantUser(_ userId: Snowflake) -> User? {
        if userId == session.currentUser?.id {
            return session.currentUser
        }
        return session.knownUsers[userId]
    }

    private var phaseColor: Color {
        if session.voice.isRinging { return .orange }
        if case .connected = session.voice.phase { return .green }
        return .orange
    }
}

/// Banner shown when someone is calling this account.
struct IncomingCallBanner: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if let channel = session.incomingCall {
            HStack(spacing: 12) {
                let caller = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
                AvatarView(user: caller, diameter: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(caller?.displayName ?? channel.name ?? "Incoming call")
                        .font(.callout.bold())
                    Text("Incoming call")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await session.declineIncomingCall() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button {
                    Task { await session.acceptIncomingCall() }
                } label: {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
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
