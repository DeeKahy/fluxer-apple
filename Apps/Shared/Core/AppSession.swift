import Foundation
import Observation
import os
import FluxerKit

let gatewayLog = Logger(subsystem: "dev.deekahy.fluxer", category: "gateway")

/// Top level app state: authentication, the API client, and the signed-in user.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case loggedOut
        case captchaPending
        case mfaPending
        case emailConfirmationPending(email: String)
        case handoffPending(code: String)
        case loggingIn
        case loggedIn
    }

    var phase: Phase = .loggedOut
    var currentUser: User?
    var guilds: [Guild] = []
    var privateChannels: [Channel] = []
    var messages: [Snowflake: [Message]] = [:]
    var gatewayConnected = false
    /// Last read message per channel.
    var readStates: [Snowflake: Snowflake] = [:]
    /// False until READY delivers read states. Before that the cached
    /// channel list would otherwise render every conversation as unread.
    var readStatesSynced = false
    /// Unread mention counts per channel, from read states and live mentions.
    var mentionCounts: [Snowflake: Int] = [:]
    /// Users currently typing per channel, with when their indicator expires.
    var typingUsers: [Snowflake: [Snowflake: Date]] = [:]
    /// Users seen in READY, message authors, and DM recipients, for name lookups.
    var knownUsers: [Snowflake: User] = [:]
    /// Presence status per user: online, idle, dnd, offline.
    var presences: [Snowflake: String] = [:]
    /// Friends, requests, and blocks keyed by the other user's id.
    var relationships: [Snowflake: Relationship] = [:]
    /// Own member record per guild, for permission checks.
    var myMembers: [Snowflake: GuildMember] = [:]
    /// Member lists per guild, loaded on demand.
    var guildMembers: [Snowflake: [GuildMember]] = [:]
    /// When slowmode allows the next message per channel.
    var slowmodeUntil: [Snowflake: Date] = [:]
    /// DM channels pinned to the top of the sidebar.
    var pinnedDMIds: Set<Snowflake> = []
    /// Read position captured when a channel was opened, for the new
    /// messages divider. Unlike readStates this doesn't advance while
    /// the channel stays open.
    var unreadMarkers: [Snowflake: Snowflake] = [:]
    /// Bottom-most message on screen when a channel was last left, so the
    /// view can reopen at the same spot. Empty means open at the newest.
    var scrollAnchors: [Snowflake: Snowflake] = [:]
    /// The user's own chosen status.
    var myStatus = "online"
    var lastError: String?

    /// Optimistic sends awaiting their server echo, keyed by nonce.
    /// The value is the placeholder message swapped out on reconcile.
    struct PendingSend {
        let channelId: Snowflake
        let placeholderId: Snowflake
    }
    var pendingSends: [String: PendingSend] = [:]

    /// The channel currently on screen; new messages there are acked as read.
    var activeChannelId: Snowflake?

    /// Set when a channel mention is tapped; the navigation layer consumes it.
    var channelJump: Channel?

    var lastTypingSent: [Snowflake: Date] = [:]
    var cacheSaveTask: Task<Void, Never>?
    /// Channels whose in-memory messages came from cache or predate a
    /// reconnect, needing a server refresh next time they're viewed.
    var staleChannels: Set<Snowflake> = []

    /// Voice connection owner.
    let voice = VoiceManager()
    /// A DM call currently ringing this account.
    var incomingCall: Channel?
    /// Who is in which voice channel, kept from READY and voice updates.
    var voiceChannelUsers: [Snowflake: Set<Snowflake>] = [:]
    /// Users currently muted in voice, self or server muted, from the same
    /// sources. Rendered as mic-off badges on tiles and occupant rows.
    var voiceMutedUsers: Set<Snowflake> = []

    /// Whether a voice participant should show a mute badge. The local
    /// toggle wins for ourselves so the badge flips instantly.
    func isVoiceMuted(_ userId: Snowflake) -> Bool {
        if userId == currentUser?.id, voice.isActive {
            return voice.muted
        }
        return voiceMutedUsers.contains(userId)
    }

    var channelsWithFullHistory: Set<Snowflake> = []
    var channelsLoadingOlder: Set<Snowflake> = []
    var lastChannelByGuild: [Snowflake: Snowflake] = {
        let stored = UserDefaults.standard.dictionary(forKey: lastChannelDefaultsKey) as? [String: String] ?? [:]
        var result: [Snowflake: Snowflake] = [:]
        for (guild, channel) in stored {
            if let guildId = Snowflake(string: guild), let channelId = Snowflake(string: channel) {
                result[guildId] = channelId
            }
        }
        return result
    }()
    /// Invite lookups cached per code; nil value means the code is invalid.
    var inviteCache: [String: APIClient.Invite?] = [:]


    var gateway: GatewayClient?
    var gatewayEventTask: Task<Void, Never>?
    var reconnectAttempts = 0

    var client: APIClient
    var mfaTicket: String?
    var pendingLogin: (email: String, password: String)?
    var ipAuthTicket: String?
    var ipAuthPollTask: Task<Void, Never>?
    var handoffCode: String?
    var handoffPollTask: Task<Void, Never>?

    /// Where the person completes a browser login for this instance.
    static let browserLoginURL = URL(string: "https://web.fluxer.app/login?handoff=1")!

    /// The instance this app talks to, fluxer.app unless changed at login.
    var instanceConfig: InstanceConfig = AppSession.loadStoredInstanceConfig()

    static let instanceDefaultsKey = "instanceConfig"

    static func loadStoredInstanceConfig() -> InstanceConfig {
        guard let data = UserDefaults.standard.data(forKey: instanceDefaultsKey),
              let config = try? JSONDecoder().decode(InstanceConfig.self, from: data)
        else { return .fluxerApp }
        return config
    }

    init() {
        let config = Self.loadStoredInstanceConfig()
        self.instanceConfig = config
        self.client = APIClient(baseURL: config.apiBase)
        MediaURLs.configure(with: config)
        voice.sendVoiceState = { [weak self] guildId, channelId, mute, connectionId in
            await self?.gateway?.updateVoiceState(
                guildId: guildId,
                channelId: channelId,
                selfMute: mute,
                connectionId: connectionId
            )
        }
        voice.heartbeat = { [weak self] channelId, connectionId in
            guard let self else { return }
            try? await self.client.voiceHeartbeat(in: channelId, connectionId: connectionId)
        }
        voice.endHeartbeat = { [weak self] channelId, connectionId in
            guard let self else { return }
            try? await self.client.endVoiceHeartbeat(in: channelId, connectionId: connectionId)
        }
        if let token = KeychainStore.loadToken() {
            loadCachedState()
            Task { await self.restore(token: token) }
        }
    }

    /// Switches to a different Fluxer instance while logged out. Reads the
    /// instance's bootstrap config and rebuilds the API client against it.
    func useInstance(_ input: String) async -> Bool {
        guard phase == .loggedOut else { return false }
        do {
            let config = try await InstanceConfig.load(from: input)
            instanceConfig = config
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Self.instanceDefaultsKey)
            }
            client = APIClient(baseURL: config.apiBase)
            MediaURLs.configure(with: config)
            lastError = nil
            return true
        } catch {
            lastError = "Couldn't read that instance: \(Self.describe(error))"
            return false
        }
    }

    func resetToDefaultInstance() {
        guard phase == .loggedOut else { return }
        instanceConfig = .fluxerApp
        UserDefaults.standard.removeObject(forKey: Self.instanceDefaultsKey)
        client = APIClient()
        MediaURLs.configure(with: .fluxerApp)
    }

    func restore(token: String) async {
        phase = .loggingIn
        await client.setCredential(.user(token: token))
        do {
            currentUser = try await client.currentUser()
            phase = .loggedIn
            connectGateway(token: token)
        } catch {
            KeychainStore.deleteToken()
            cacheSaveTask?.cancel()
            DiskCache.clear()
            await client.setCredential(nil)
            phase = .loggedOut
        }
    }

    /// Shared tail of every successful auth path: persist the token,
    /// fetch the account, and bring up the gateway.
    func finishLogin(token: String) async {
        KeychainStore.saveToken(token)
        phase = .loggingIn
        do {
            currentUser = try await client.currentUser()
            phase = .loggedIn
            connectGateway(token: token)
        } catch {
            lastError = Self.describe(error)
            phase = .loggedOut
        }
    }

    func login(email: String, password: String, captcha: CaptchaSolution? = nil) async {
        phase = .loggingIn
        lastError = nil
        do {
            switch try await client.login(email: email, password: password, captcha: captcha) {
            case .success(let token):
                pendingLogin = nil
                await finishLogin(token: token)
            case .mfaRequired(let ticket, let totp, _):
                pendingLogin = nil
                if totp {
                    mfaTicket = ticket
                    phase = .mfaPending
                } else {
                    lastError = "This account uses a passkey. Use \"Sign in with browser\" below."
                    phase = .loggedOut
                }
            case .ipAuthorizationRequired(let ticket, let email):
                pendingLogin = nil
                ipAuthTicket = ticket
                phase = .emailConfirmationPending(email: email)
                startIpAuthPolling()
            }
        } catch APIError.captchaRequired {
            pendingLogin = (email, password)
            phase = .captchaPending
        } catch APIError.invalidCaptcha {
            pendingLogin = (email, password)
            lastError = "Captcha check failed, try again."
            phase = .captchaPending
        } catch {
            lastError = Self.describe(error)
            phase = .loggedOut
        }
    }

    func submitCaptcha(token: String) async {
        guard let pending = pendingLogin else {
            phase = .loggedOut
            return
        }
        let provider = instanceConfig.captchaProvider == "turnstile" ? "turnstile" : "hcaptcha"
        await login(
            email: pending.email,
            password: pending.password,
            captcha: CaptchaSolution(token: token, type: provider)
        )
    }

    func cancelCaptcha() {
        pendingLogin = nil
        phase = .loggedOut
    }

    /// Polls until the person clicks the confirmation link Fluxer emailed them.
    func startIpAuthPolling() {
        ipAuthPollTask?.cancel()
        ipAuthPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let ticket = ipAuthTicket, case .emailConfirmationPending = phase else { return }
                guard let status = try? await client.pollIpAuthorization(ticket: ticket) else { continue }
                if status.completed {
                    ipAuthTicket = nil
                    if let token = status.token {
                        await finishLogin(token: token)
                    } else {
                        lastError = "Device confirmed, sign in again."
                        phase = .loggedOut
                    }
                    return
                }
            }
        }
    }

    /// Starts a browser login: get a pairing code, show it, and poll for
    /// approval while the person signs in on the web and enters the code.
    func startBrowserLogin() async {
        lastError = nil
        do {
            let initiation = try await client.initiateHandoff()
            handoffCode = initiation.code
            phase = .handoffPending(code: initiation.code)
            startHandoffPolling()
        } catch {
            lastError = Self.describe(error)
            phase = .loggedOut
        }
    }

    func startHandoffPolling() {
        handoffPollTask?.cancel()
        handoffPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let code = handoffCode, case .handoffPending = phase else { return }
                guard let status = try? await client.pollHandoff(code: code) else { continue }
                if status.isCompleted, let token = status.token {
                    handoffCode = nil
                    await finishLogin(token: token)
                    return
                }
                if status.isExpired {
                    handoffCode = nil
                    lastError = "The code expired, try again."
                    phase = .loggedOut
                    return
                }
            }
        }
    }

    func cancelBrowserLogin() {
        handoffPollTask?.cancel()
        handoffPollTask = nil
        if let code = handoffCode {
            Task { try? await client.cancelHandoff(code: code) }
        }
        handoffCode = nil
        phase = .loggedOut
    }

    func resendConfirmationEmail() async {
        guard let ticket = ipAuthTicket else { return }
        try? await client.resendIpAuthorization(ticket: ticket)
    }

    func cancelEmailConfirmation() {
        ipAuthPollTask?.cancel()
        ipAuthPollTask = nil
        ipAuthTicket = nil
        phase = .loggedOut
    }

    func submitMfaCode(_ code: String) async {
        guard let ticket = mfaTicket else { return }
        phase = .loggingIn
        lastError = nil
        do {
            let token = try await client.loginMfaTotp(code: code, ticket: ticket)
            mfaTicket = nil
            await finishLogin(token: token)
        } catch {
            lastError = Self.describe(error)
            phase = .mfaPending
        }
    }

    func logout() async {
        if voice.isActive {
            await voice.leave()
        }
        voiceChannelUsers = [:]
        gatewayEventTask?.cancel()
        gatewayEventTask = nil
        if let gateway {
            await gateway.disconnect()
        }
        gateway = nil
        gatewayConnected = false
        try? await client.logout()
        KeychainStore.deleteToken()
        cacheSaveTask?.cancel()
        DiskCache.clear()
        ipAuthPollTask?.cancel()
        ipAuthPollTask = nil
        ipAuthTicket = nil
        currentUser = nil
        guilds = []
        privateChannels = []
        messages = [:]
        channelsWithFullHistory = []
        channelsLoadingOlder = []
        staleChannels = []
        readStates = [:]
        readStatesSynced = false
        typingUsers = [:]
        knownUsers = [:]
        presences = [:]
        relationships = [:]
        myMembers = [:]
        guildMembers = [:]
        slowmodeUntil = [:]
        pinnedDMIds = []
        unreadMarkers = [:]
        scrollAnchors = [:]
        myStatus = "online"
        lastTypingSent = [:]
        activeChannelId = nil
        mfaTicket = nil
        pendingLogin = nil
        phase = .loggedOut
    }

    func loadGuilds() async {
        do {
            guilds = try await client.myGuilds()
        } catch {
            lastError = Self.describe(error)
        }
    }
}
