import SwiftUI
import LiveKit
import FluxerKit

/// Call screen that takes over the desktop chat column, per the comp:
/// header with a live dot and layout toggle, participant tiles, a chat
/// panel for voice channels, and the round control bar.
struct DesktopCallView: View {
    @Environment(AppSession.self) private var session

    let connectedAt: Date?
    let onMinimize: () -> Void

    private enum Layout: String {
        case grid
        case speaker
    }

    @State private var layout: Layout = .grid
    @State private var showChat = true

    private var tiles: [VoiceManager.VideoTile] {
        session.voice.videoTiles
    }

    private var shareTile: VoiceManager.VideoTile? {
        tiles.first { $0.isScreenShare }
    }

    private var voiceOnlyParticipants: [Snowflake] {
        let withVideo = Set(tiles.compactMap(\.userId))
        return session.voice.roomParticipantIds.filter { !withVideo.contains($0) }.sorted()
    }

    private var connectedChannel: Channel? {
        session.voice.connectedChannelId.flatMap { session.findChannel($0) }
    }

    private var isVoiceChannel: Bool {
        connectedChannel?.type == .guildVoice
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 16) {
                Group {
                    if let share = shareTile {
                        shareLayout(share)
                    } else if layout == .speaker {
                        speakerLayout
                    } else {
                        gridLayout
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showChat, isVoiceChannel, let channel = connectedChannel {
                    voiceChatPanel(channel)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            controlBar
        }
        .background(
            RadialGradient(
                colors: [Color(hex: 0x17171F), Color(hex: 0x08080C)],
                center: .top,
                startRadius: 0,
                endRadius: 900
            )
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            PulseDot()
            Text(channelName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            CallTimerText(connectedAt: connectedAt)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Spacer()
            if shareTile == nil {
                HStack(spacing: 2) {
                    layoutTab("Grid", mode: .grid)
                    layoutTab("Speaker", mode: .speaker)
                }
                .padding(3)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            }
            if isVoiceChannel {
                callHeaderButton(
                    "bubble.left",
                    tint: showChat ? Theme.accentSoft : Theme.icon
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { showChat.toggle() }
                }
                .help("Channel chat")
            }
            callHeaderButton("minus") { onMinimize() }
                .help("Minimize")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func layoutTab(_ label: String, mode: Layout) -> some View {
        Button {
            layout = mode
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(layout == mode ? .white : Color(hex: 0x9A9AA8))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(
                    layout == mode ? Theme.accent : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func callHeaderButton(
        _ icon: String,
        tint: Color = Theme.icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SquishButtonStyle())
    }

    // MARK: Layouts

    private var gridLayout: some View {
        GeometryReader { geometry in
            let count = max(tiles.count + voiceOnlyParticipants.count, 1)
            let columns = count <= 2 ? 2 : (count <= 4 ? 2 : 3)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns),
                spacing: 14
            ) {
                let rows = Int(ceil(Double(count) / Double(columns)))
                let tileHeight = max((geometry.size.height - CGFloat(rows - 1) * 14) / CGFloat(rows), 150)
                ForEach(tiles.filter { !$0.isScreenShare }) { tile in
                    videoTile(tile)
                        .frame(height: tileHeight)
                }
                ForEach(voiceOnlyParticipants, id: \.self) { userId in
                    avatarTile(userId, avatarSize: 84, nameSize: 14)
                        .frame(height: tileHeight)
                }
            }
        }
    }

    private var speakerLayout: some View {
        VStack(spacing: 14) {
            Group {
                if let speakerId = currentSpeaker {
                    if let tile = tiles.first(where: { $0.userId == speakerId && !$0.isScreenShare }) {
                        videoTile(tile, radius: 18)
                    } else {
                        avatarTile(speakerId, avatarSize: 120, nameSize: 16, radius: 18, speakingRing: true)
                    }
                } else {
                    avatarTile(session.currentUser?.id, avatarSize: 120, nameSize: 16, radius: 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(tiles.filter { !$0.isScreenShare }) { tile in
                        videoTile(tile, radius: 12, nameSize: 11)
                            .frame(width: 150, height: 96)
                    }
                    ForEach(voiceOnlyParticipants, id: \.self) { userId in
                        avatarTile(userId, avatarSize: 44, nameSize: 11, radius: 12)
                            .frame(width: 150, height: 96)
                    }
                }
            }
            .frame(height: 96)
        }
    }

    private func shareLayout(_ share: VoiceManager.VideoTile) -> some View {
        HStack(spacing: 16) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    Text(shareLabel(share))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.icon)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.03))
                GeometryReader { geometry in
                    SwiftUIVideoView(share.track, layoutMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .background(Color(hex: 0x0E1116))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(tiles.filter { !$0.isScreenShare }) { tile in
                        videoTile(tile, radius: 12, nameSize: 11)
                            .frame(height: 96)
                    }
                    ForEach(voiceOnlyParticipants, id: \.self) { userId in
                        avatarTile(userId, avatarSize: 40, nameSize: 11, radius: 12)
                            .frame(height: 96)
                    }
                }
            }
            .frame(width: 150)
        }
    }

    private var currentSpeaker: Snowflake? {
        if let speaking = session.voice.speakingUserIds.sorted().first {
            return speaking
        }
        return session.voice.roomParticipantIds.sorted().first
    }

    // MARK: Tiles

    private func videoTile(
        _ tile: VoiceManager.VideoTile,
        radius: CGFloat = 16,
        nameSize: CGFloat = 14
    ) -> some View {
        GeometryReader { geometry in
            SwiftUIVideoView(tile.track, layoutMode: tile.isScreenShare ? .fit : .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .id(tile.id)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(alignment: .bottomLeading) {
            tileName(userName(tile.userId), size: nameSize)
        }
        .overlay(alignment: .bottomTrailing) {
            if let userId = tile.userId, !tile.isScreenShare, session.isVoiceMuted(userId) {
                muteBadge.padding(10)
            }
        }
        .overlay {
            if let userId = tile.userId,
               session.voice.speakingUserIds.contains(userId),
               !tile.isScreenShare {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.green.opacity(0.7), lineWidth: 3)
            }
        }
    }

    private func avatarTile(
        _ userId: Snowflake?,
        avatarSize: CGFloat,
        nameSize: CGFloat,
        radius: CGFloat = 16,
        speakingRing: Bool = false
    ) -> some View {
        let speaking = userId.map { session.voice.speakingUserIds.contains($0) } ?? false
        let muted = userId.map { session.isVoiceMuted($0) } ?? false
        return RoundedRectangle(cornerRadius: radius)
            .fill(userId.map { Theme.tileColor(for: $0) } ?? Theme.deskTile)
            .overlay {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.28))
                        .frame(width: avatarSize, height: avatarSize)
                    AvatarView(user: user(userId), diameter: avatarSize)
                }
            }
            .overlay(alignment: .bottomLeading) {
                tileName(userName(userId), size: nameSize)
            }
            .overlay(alignment: .bottomTrailing) {
                if muted {
                    muteBadge.padding(10)
                } else if speaking {
                    SpeakingWave()
                        .padding(10)
                }
            }
            .overlay {
                if speaking || speakingRing {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Theme.green.opacity(0.7), lineWidth: 3)
                }
            }
    }

    private var muteBadge: some View {
        Image(systemName: "mic.slash.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.red)
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())
    }

    private func tileName(_ name: String, size: CGFloat) -> some View {
        Text(name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .lineLimit(1)
    }

    private func user(_ userId: Snowflake?) -> User? {
        guard let userId else { return nil }
        return userId == session.currentUser?.id ? session.currentUser : session.knownUsers[userId]
    }

    private func userName(_ userId: Snowflake?) -> String {
        guard let userId else { return "Unknown" }
        let name = user(userId)?.displayName ?? "Unknown"
        return userId == session.currentUser?.id ? "\(name) (you)" : name
    }

    private func shareLabel(_ tile: VoiceManager.VideoTile) -> String {
        "\(userName(tile.userId)) is sharing their screen"
    }

    private var channelName: String {
        guard let channel = connectedChannel else { return "Call" }
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }

    // MARK: Voice channel chat

    private func voiceChatPanel(_ channel: Channel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentSoft)
                Text(channel.name ?? "voice")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("chat")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
            MessageView(channel: channel)
                .id(channel.id)
                .environment(\.desktopChrome, true)
        }
        .frame(width: 340)
        .background(Theme.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            roundControl(
                icon: session.voice.muted ? "mic.slash.fill" : "mic.fill",
                active: session.voice.muted
            ) {
                Task { await session.voice.toggleMute() }
            }
            roundControl(
                icon: session.voice.cameraEnabled ? "video.fill" : "video.slash.fill",
                active: !session.voice.cameraEnabled
            ) {
                Task { await session.voice.toggleCamera() }
            }
            #if os(macOS)
            roundControl(
                icon: "rectangle.on.rectangle",
                active: session.voice.screenSharing,
                activeColor: Theme.accent
            ) {
                Task { await session.voice.toggleScreenShare() }
            }
            #endif
            Button {
                Task { await session.voice.leave() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 52)
                    .background(Theme.red, in: RoundedRectangle(cornerRadius: 26))
                    .contentShape(RoundedRectangle(cornerRadius: 26))
            }
            .buttonStyle(SquishButtonStyle())
            .padding(.leading, 8)
        }
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }

    private func roundControl(
        icon: String,
        active: Bool,
        activeColor: Color = Theme.red,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(active ? .white : Theme.text)
                .frame(width: 52, height: 52)
                .liquidGlassCircle(tint: active ? activeColor : nil)
                .contentShape(Circle())
        }
        .buttonStyle(SquishButtonStyle())
    }
}

/// Minimized call pill floating over the chat column, desktop comp style.
struct DesktopCallPill: View {
    @Environment(AppSession.self) private var session

    let connectedAt: Date?
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PulseDot()
            VStack(alignment: .leading, spacing: 1) {
                Text("In call · \(channelName)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    CallTimerText(connectedAt: connectedAt)
                    Text(" · \(max(session.voice.participantCount, 1)) in call")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            Button {
                Task { await session.voice.toggleMute() }
            } label: {
                Image(systemName: session.voice.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(session.voice.muted ? .white : Theme.text)
                    .frame(width: 34, height: 34)
                    .background(
                        session.voice.muted ? Theme.red : Theme.deskTile,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
            Button(action: onOpen) {
                Text("Open")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
            Button {
                Task { await session.voice.leave() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.red, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 20)
        .shadow(color: .black.opacity(0.35), radius: 20, y: 16)
    }

    private var channelName: String {
        guard let channelId = session.voice.connectedChannelId,
              let channel = session.findChannel(channelId)
        else { return "Voice" }
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }
}

/// Green dot with the comp's soft pulse ring.
struct PulseDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.green)
            .frame(width: 10, height: 10)
            .background {
                Circle()
                    .stroke(Theme.green.opacity(pulsing ? 0 : 0.55), lineWidth: 3)
                    .scaleEffect(pulsing ? 2.2 : 1)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

/// mm:ss ticking label for the current call.
struct CallTimerText: View {
    let connectedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsed(at: context.date))
                .monospacedDigit()
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let connectedAt else { return "0:00" }
        let seconds = max(Int(date.timeIntervalSince(connectedAt)), 0)
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}

/// Three animated green bars, the comp's speaking indicator.
struct SpeakingWave: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.green)
                    .frame(width: 3, height: animating ? 15 : 5)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .frame(width: 26, height: 26)
        .background(.black.opacity(0.45), in: Circle())
        .onAppear { animating = true }
    }
}
