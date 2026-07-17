import SwiftUI
import LiveKit
import FluxerKit

/// Full call screen: screen shares large, cameras in a grid, voice-only
/// participants as avatar tiles, controls along the bottom.
struct VoiceStageView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private var cameraColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160), spacing: 8)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    let tiles = session.voice.videoTiles
                    let shares = tiles.filter(\.isScreenShare)
                    let cameras = tiles.filter { !$0.isScreenShare }

                    ForEach(shares) { tile in
                        videoTile(tile)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }

                    LazyVGrid(columns: cameraColumns, spacing: 8) {
                        ForEach(cameras) { tile in
                            videoTile(tile)
                                .aspectRatio(4 / 3, contentMode: .fit)
                        }
                        ForEach(voiceOnlyParticipants, id: \.self) { userId in
                            avatarTile(userId)
                                .aspectRatio(4 / 3, contentMode: .fit)
                        }
                    }
                }
                .padding(12)
            }
            .background(.black)
            .navigationTitle(channelName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .safeAreaInset(edge: .bottom) {
                controls
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
        .onChange(of: session.voice.isActive) { _, active in
            if !active {
                dismiss()
            }
        }
    }

    private var voiceOnlyParticipants: [Snowflake] {
        let withVideo = Set(session.voice.videoTiles.compactMap(\.userId))
        return session.voice.roomParticipantIds.filter { !withVideo.contains($0) }.sorted()
    }

    private func videoTile(_ tile: VoiceManager.VideoTile) -> some View {
        // The renderer only scales correctly when handed a concrete frame;
        // left to implicit layout it draws at native size in a corner.
        GeometryReader { geometry in
            SwiftUIVideoView(tile.track, layoutMode: tile.isScreenShare ? .fit : .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .id(tile.id)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            nameBadge(tile.userId, suffix: tile.isScreenShare ? "screen" : nil)
        }
        .overlay {
            if let userId = tile.userId, session.voice.speakingUserIds.contains(userId), !tile.isScreenShare {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.green, lineWidth: 2.5)
            }
        }
    }

    private func avatarTile(_ userId: Snowflake) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary.opacity(0.4))
            .overlay {
                AvatarView(user: participantUser(userId), diameter: 56)
                    .overlay {
                        if session.voice.speakingUserIds.contains(userId) {
                            Circle().strokeBorder(.green, lineWidth: 3)
                        }
                    }
            }
            .overlay(alignment: .bottomLeading) {
                nameBadge(userId, suffix: nil)
            }
    }

    private func nameBadge(_ userId: Snowflake?, suffix: String?) -> some View {
        let name = userId.flatMap { participantUser($0)?.displayName } ?? "Unknown"
        return Text(suffix.map { "\(name)'s \($0)" } ?? name)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }

    private func participantUser(_ userId: Snowflake) -> User? {
        userId == session.currentUser?.id ? session.currentUser : session.knownUsers[userId]
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                Task { await session.voice.toggleMute() }
            } label: {
                Image(systemName: session.voice.muted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.bordered)
            .tint(session.voice.muted ? .red : nil)

            Button {
                Task { await session.voice.toggleCamera() }
            } label: {
                Image(systemName: session.voice.cameraEnabled ? "video.fill" : "video.slash.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.bordered)
            .tint(session.voice.cameraEnabled ? .green : nil)

            Button {
                Task {
                    await session.voice.leave()
                    dismiss()
                }
            } label: {
                Image(systemName: "phone.down.fill")
                    .frame(width: 28)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var channelName: String {
        guard let channelId = session.voice.connectedChannelId,
              let channel = session.findChannel(channelId)
        else { return "Call" }
        if let name = channel.name, !name.isEmpty {
            return name
        }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }
}
