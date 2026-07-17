import SwiftUI
import LiveKit
import FluxerKit
#if os(macOS)
import AVFoundation
#endif

/// Full call screen with two layouts. Grid shows everything; tapping a
/// video focuses it full size with pinch zoom and pan, and the rest of
/// the room rides in a thumbnail strip.
struct VoiceStageView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var focusedTileId: String?
    #if os(macOS)
    @State private var cameraDevices: [AVCaptureDevice] = []
    #endif

    private var tiles: [VoiceManager.VideoTile] {
        session.voice.videoTiles
    }

    private var focusedTile: VoiceManager.VideoTile? {
        focusedTileId.flatMap { id in tiles.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let focused = focusedTile {
                    focusLayout(focused)
                } else {
                    gridLayout
                }
            }
            .background(.black)
            .navigationTitle(channelName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                if focusedTile != nil {
                    Button("Grid", systemImage: "square.grid.2x2") {
                        focusedTileId = nil
                    }
                }
            }
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
        // Focus a screen share the moment one appears; unfocus tiles that
        // stopped, so the view never points at a dead stream.
        .onChange(of: tiles.map(\.id)) { old, new in
            if let focusedTileId, !new.contains(focusedTileId) {
                self.focusedTileId = nil
            }
            if let share = tiles.first(where: { $0.isScreenShare && !$0.isLocal }),
               !old.contains(share.id) {
                focusedTileId = share.id
            }
        }
    }

    // MARK: Layouts

    private var gridLayout: some View {
        ScrollView {
            VStack(spacing: 10) {
                let shares = tiles.filter(\.isScreenShare)
                let cameras = tiles.filter { !$0.isScreenShare }

                ForEach(shares) { tile in
                    videoTile(tile)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
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
    }

    private func focusLayout(_ focused: VoiceManager.VideoTile) -> some View {
        VStack(spacing: 8) {
            ZoomableVideoView(tile: focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    nameBadge(focused.userId, suffix: focused.isScreenShare ? "screen" : nil)
                }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tiles.filter { $0.id != focused.id }) { tile in
                        videoTile(tile)
                            .frame(width: 120, height: 80)
                    }
                    ForEach(voiceOnlyParticipants, id: \.self) { userId in
                        avatarTile(userId)
                            .frame(width: 120, height: 80)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 88)
        }
        .padding(.vertical, 8)
    }

    private var voiceOnlyParticipants: [Snowflake] {
        let withVideo = Set(tiles.compactMap(\.userId))
        return session.voice.roomParticipantIds.filter { !withVideo.contains($0) }.sorted()
    }

    // MARK: Tiles

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
        .onTapGesture {
            focusedTileId = tile.id
        }
    }

    private func avatarTile(_ userId: Snowflake) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary.opacity(0.4))
            .overlay {
                AvatarView(user: participantUser(userId), diameter: 44)
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

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                Task { await session.voice.toggleMute() }
            } label: {
                Image(systemName: session.voice.muted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 26)
            }
            .buttonStyle(.bordered)
            .tint(session.voice.muted ? .red : nil)

            Button {
                Task { await session.voice.toggleCamera() }
            } label: {
                Image(systemName: session.voice.cameraEnabled ? "video.fill" : "video.slash.fill")
                    .frame(width: 26)
            }
            .buttonStyle(.bordered)
            .tint(session.voice.cameraEnabled ? .green : nil)

            #if os(iOS)
            if session.voice.cameraEnabled {
                Button {
                    Task { await session.voice.flipCamera() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .frame(width: 26)
                }
                .buttonStyle(.bordered)
            }
            #else
            Menu {
                ForEach(cameraDevices, id: \.uniqueID) { device in
                    Button(device.localizedName) {
                        Task { await session.voice.useCamera(device: device) }
                    }
                }
            } label: {
                Image(systemName: "web.camera")
                    .frame(width: 26)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 44)
            .task {
                cameraDevices = await session.voice.cameraDevices()
            }

            Button {
                Task { await session.voice.toggleScreenShare() }
            } label: {
                Image(systemName: session.voice.screenSharing
                    ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                    .frame(width: 26)
            }
            .buttonStyle(.bordered)
            .tint(session.voice.screenSharing ? .green : nil)
            #endif

            Button {
                Task {
                    await session.voice.leave()
                    dismiss()
                }
            } label: {
                Image(systemName: "phone.down.fill")
                    .frame(width: 26)
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

/// Focused video with pinch zoom, drag pan, and double tap to toggle zoom.
private struct ZoomableVideoView: View {
    let tile: VoiceManager.VideoTile

    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            SwiftUIVideoView(tile.track, layoutMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnification(in: geometry.size))
                .simultaneousGesture(pan(in: geometry.size))
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.25)) {
                        if scale > 1 {
                            reset()
                        } else {
                            scale = 2.5
                            steadyScale = 2.5
                        }
                    }
                }
        }
        .id(tile.id)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .onChange(of: tile.id) {
            reset()
        }
    }

    private func magnification(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(steadyScale * value.magnification, 1), 8)
            }
            .onEnded { _ in
                steadyScale = scale
                if scale <= 1 {
                    withAnimation(.spring(duration: 0.2)) { reset() }
                } else {
                    clampOffset(in: size)
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: steadyOffset.width + value.translation.width,
                    height: steadyOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                clampOffset(in: size)
                steadyOffset = offset
            }
    }

    /// Keeps the zoomed content covering the viewport.
    private func clampOffset(in size: CGSize) {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        let clamped = CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
        withAnimation(.spring(duration: 0.2)) {
            offset = clamped
        }
        steadyOffset = clamped
    }

    private func reset() {
        scale = 1
        steadyScale = 1
        offset = .zero
        steadyOffset = .zero
    }
}
