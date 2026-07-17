import AVFoundation
import Foundation
import Observation
import os
import LiveKit
import FluxerKit

let voiceLog = Logger(subsystem: "dev.deekahy.fluxer", category: "voice")

/// Owns the LiveKit room. The join flow is: ask the gateway (op 4), wait
/// for VOICE_SERVER_UPDATE with a token and endpoint, connect the room,
/// publish the microphone, and heartbeat presence while connected.
@MainActor
@Observable
final class VoiceManager {
    enum Phase: Equatable {
        case idle
        case requesting(channelId: Snowflake)
        case connecting(channelId: Snowflake)
        case connected(channelId: Snowflake)
    }

    private(set) var phase: Phase = .idle
    private(set) var muted = false
    private(set) var speakingUserIds: Set<Snowflake> = []
    private(set) var roomParticipantIds: Set<Snowflake> = []
    /// Remote user ids currently in the room, to tell ringing from answered.
    private(set) var remoteParticipantIds: Set<Snowflake> = []
    /// True while a DM call is waiting for the other side to pick up.
    private(set) var isRinging = false
    private(set) var cameraEnabled = false
    /// Live video in the room: cameras and screen shares, local and remote.
    private(set) var videoTiles: [VideoTile] = []
    var lastError: String?

    struct VideoTile: Identifiable {
        let id: String
        let userId: Snowflake?
        let track: VideoTrack
        let isScreenShare: Bool
        let isLocal: Bool
    }

    private let room: Room
    private let delegateProxy = RoomDelegateProxy()
    private var heartbeatTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingGuildId: Snowflake?

    /// Wired by AppSession so the manager can drive gateway and REST.
    var sendVoiceState: ((Snowflake?, Snowflake?, Bool) async -> Void)?
    var heartbeat: ((Snowflake) async -> Void)?

    var connectedChannelId: Snowflake? {
        if case .connected(let channelId) = phase { return channelId }
        if case .connecting(let channelId) = phase { return channelId }
        if case .requesting(let channelId) = phase { return channelId }
        return nil
    }

    var isActive: Bool {
        phase != .idle
    }

    init() {
        #if targetEnvironment(simulator)
        // The simulator's voice processing audio unit fails to start
        // (error -4010), which kills the room connect. Plain audio works.
        try? AudioManager.shared.setVoiceProcessingEnabled(false)
        #endif
        room = Room()
        room.add(delegate: delegateProxy)
        delegateProxy.onChange = { [weak self] in
            Task { @MainActor in
                self?.refreshParticipants()
            }
        }
    }

    // MARK: Join and leave

    func join(channelId: Snowflake, guildId: Snowflake?, ringing: Bool = false) async {
        if connectedChannelId == channelId { return }
        if isActive {
            await leave()
        }
        lastError = nil
        isRinging = ringing
        phase = .requesting(channelId: channelId)
        pendingGuildId = guildId
        await sendVoiceState?(guildId, channelId, muted)
        // VOICE_SERVER_UPDATE continues the flow; give up if it never comes.
        Task {
            try? await Task.sleep(for: .seconds(8))
            if case .requesting(let pending) = self.phase, pending == channelId {
                self.lastError = "Couldn't reach the voice server."
                self.phase = .idle
            }
        }
    }

    func handleServerUpdate(_ update: VoiceServerUpdate) async {
        guard case .requesting(let channelId) = phase else { return }
        guard let url = update.url else {
            lastError = "Voice server sent a bad endpoint."
            phase = .idle
            return
        }
        phase = .connecting(channelId: channelId)
        do {
            try await room.connect(url: url.absoluteString, token: update.token)
            do {
                try await room.localParticipant.setMicrophone(enabled: !muted)
            } catch {
                // Stay in the call listen-only rather than dropping it.
                voiceLog.error("Microphone publish failed: \(String(describing: error))")
                muted = true
                lastError = "Microphone unavailable, connected listen only."
            }
            phase = .connected(channelId: channelId)
            refreshParticipants()
            startHeartbeat(channelId: channelId)
            startRefreshLoop()
            onConnected?()
            onConnected = nil
            voiceLog.info("Voice connected to channel \(channelId.stringValue)")
        } catch {
            voiceLog.error("Voice connect failed: \(String(describing: error))")
            lastError = "Voice connection failed."
            phase = .idle
            await sendVoiceState?(pendingGuildId, nil, muted)
        }
    }

    func leave() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRinging = false
        remoteParticipantIds = []
        cameraEnabled = false
        videoTiles = []
        let guildId = pendingGuildId
        pendingGuildId = nil
        phase = .idle
        speakingUserIds = []
        roomParticipantIds = []
        await room.disconnect()
        await sendVoiceState?(guildId, nil, muted)
    }

    func toggleMute() async {
        muted.toggle()
        try? await room.localParticipant.setMicrophone(enabled: !muted)
    }

    func toggleCamera() async {
        do {
            try await room.localParticipant.setCamera(enabled: !cameraEnabled)
            cameraEnabled.toggle()
            refreshParticipants()
        } catch {
            voiceLog.error("Camera toggle failed: \(String(describing: error))")
            lastError = "Camera unavailable."
        }
    }

    /// Switches between front and back camera while publishing.
    func flipCamera() async {
        guard let publication = room.localParticipant.videoTracks.first(where: { $0.source == .camera }),
              let track = publication.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer
        else { return }
        _ = try? await capturer.switchCameraPosition()
    }

    #if os(macOS)
    private(set) var screenSharing = false

    func toggleScreenShare() async {
        do {
            _ = try await room.localParticipant.setScreenShare(enabled: !screenSharing)
            screenSharing.toggle()
            refreshParticipants()
        } catch {
            voiceLog.error("Screen share failed: \(String(describing: error))")
            lastError = "Screen share failed. Grant screen recording permission in System Settings."
        }
    }

    /// Cameras available on this machine.
    func cameraDevices() async -> [AVCaptureDevice] {
        (try? await CameraCapturer.captureDevices()) ?? []
    }

    /// Republishes the camera from a specific device.
    func useCamera(device: AVCaptureDevice) async {
        do {
            if cameraEnabled {
                try await room.localParticipant.setCamera(enabled: false)
            }
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: CameraCaptureOptions(device: device)
            )
            cameraEnabled = true
            refreshParticipants()
        } catch {
            voiceLog.error("Camera device switch failed: \(String(describing: error))")
            lastError = "Couldn't use that camera."
        }
    }
    #endif

    // MARK: Room state

    private func refreshParticipants() {
        var ids: Set<Snowflake> = []
        var remotes: Set<Snowflake> = []
        let participants = [room.localParticipant as Participant] + Array(room.remoteParticipants.values)
        for participant in participants {
            guard let id = Self.userId(of: participant) else { continue }
            ids.insert(id)
            if participant is RemoteParticipant {
                remotes.insert(id)
            }
        }
        roomParticipantIds = ids
        remoteParticipantIds = remotes
        speakingUserIds = Set(room.activeSpeakers.compactMap(Self.userId(of:)))
        rebuildVideoTiles()
        if isRinging && !remotes.isEmpty {
            isRinging = false
            onCallAnswered?()
        }
    }

    private func rebuildVideoTiles() {
        var tiles: [VideoTile] = []
        let participants = [room.localParticipant as Participant] + Array(room.remoteParticipants.values)
        for participant in participants {
            let userId = Self.userId(of: participant)
            let isLocal = participant is LocalParticipant
            for publication in participant.videoTracks {
                guard let track = publication.track as? VideoTrack, !publication.isMuted else { continue }
                tiles.append(
                    VideoTile(
                        id: "\(participant.identity?.stringValue ?? "?")-\(publication.sid.stringValue)",
                        userId: userId,
                        track: track,
                        isScreenShare: publication.source == .screenShareVideo,
                        isLocal: isLocal
                    )
                )
            }
        }
        // Screen shares first, then remote cameras, own camera last.
        videoTiles = tiles.sorted {
            if $0.isScreenShare != $1.isScreenShare { return $0.isScreenShare }
            if $0.isLocal != $1.isLocal { return !$0.isLocal }
            return $0.id < $1.id
        }
    }

    /// Called once when a rung DM call gets picked up.
    var onCallAnswered: (() -> Void)?

    /// Called once after the room connects, used to ring after the call
    /// exists server side, the same order the official client uses.
    var onConnected: (() -> Void)?

    private static func userId(of participant: Participant) -> Snowflake? {
        guard let identity = participant.identity?.stringValue else { return nil }
        // Identities are user ids, possibly with a suffix after a colon.
        let base = identity.split(separator: ":").first.map(String.init) ?? identity
        return Snowflake(string: base)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.refreshParticipants()
            }
        }
    }

    private func startHeartbeat(channelId: Snowflake) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                await heartbeat?(channelId)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

/// Bridges LiveKit's delegate callbacks onto a simple change signal.
private final class RoomDelegateProxy: RoomDelegate, @unchecked Sendable {
    var onChange: (() -> Void)?

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        onChange?()
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        onChange?()
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        onChange?()
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        onChange?()
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        onChange?()
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        onChange?()
    }

    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        onChange?()
    }
}
