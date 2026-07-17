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

    private(set) var phase: Phase = .loggedOut
    private(set) var currentUser: User?
    private(set) var guilds: [Guild] = []
    private(set) var privateChannels: [Channel] = []
    private(set) var messages: [Snowflake: [Message]] = [:]
    private(set) var gatewayConnected = false
    /// Last read message per channel.
    private(set) var readStates: [Snowflake: Snowflake] = [:]
    /// Users currently typing per channel, with when their indicator expires.
    private(set) var typingUsers: [Snowflake: [Snowflake: Date]] = [:]
    /// Users seen in READY, message authors, and DM recipients, for name lookups.
    private(set) var knownUsers: [Snowflake: User] = [:]
    /// Presence status per user: online, idle, dnd, offline.
    private(set) var presences: [Snowflake: String] = [:]
    /// Friends, requests, and blocks keyed by the other user's id.
    private(set) var relationships: [Snowflake: Relationship] = [:]
    /// Own member record per guild, for permission checks.
    private(set) var myMembers: [Snowflake: GuildMember] = [:]
    /// Member lists per guild, loaded on demand.
    private(set) var guildMembers: [Snowflake: [GuildMember]] = [:]
    /// When slowmode allows the next message per channel.
    private(set) var slowmodeUntil: [Snowflake: Date] = [:]
    /// DM channels pinned to the top of the sidebar.
    private(set) var pinnedDMIds: Set<Snowflake> = []
    /// Read position captured when a channel was opened, for the new
    /// messages divider. Unlike readStates this doesn't advance while
    /// the channel stays open.
    private(set) var unreadMarkers: [Snowflake: Snowflake] = [:]
    /// The user's own chosen status.
    private(set) var myStatus = "online"
    var lastError: String?

    /// The channel currently on screen; new messages there are acked as read.
    var activeChannelId: Snowflake?

    /// Set when a channel mention is tapped; the navigation layer consumes it.
    var channelJump: Channel?

    private var lastTypingSent: [Snowflake: Date] = [:]

    private var gateway: GatewayClient?
    private var gatewayEventTask: Task<Void, Never>?
    private var reconnectAttempts = 0

    private var client: APIClient
    private var mfaTicket: String?
    private var pendingLogin: (email: String, password: String)?
    private var ipAuthTicket: String?
    private var ipAuthPollTask: Task<Void, Never>?
    private var handoffCode: String?
    private var handoffPollTask: Task<Void, Never>?

    /// Where the person completes a browser login for this instance.
    static let browserLoginURL = URL(string: "https://web.fluxer.app/login?handoff=1")!

    /// The instance this app talks to, fluxer.app unless changed at login.
    private(set) var instanceConfig: InstanceConfig = AppSession.loadStoredInstanceConfig()

    private static let instanceDefaultsKey = "instanceConfig"

    private static func loadStoredInstanceConfig() -> InstanceConfig {
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
        if let token = KeychainStore.loadToken() {
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

    private func restore(token: String) async {
        phase = .loggingIn
        await client.setCredential(.user(token: token))
        do {
            currentUser = try await client.currentUser()
            phase = .loggedIn
            connectGateway(token: token)
        } catch {
            KeychainStore.deleteToken()
            await client.setCredential(nil)
            phase = .loggedOut
        }
    }

    /// Shared tail of every successful auth path: persist the token,
    /// fetch the account, and bring up the gateway.
    private func finishLogin(token: String) async {
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
    private func startIpAuthPolling() {
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

    private func startHandoffPolling() {
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
        gatewayEventTask?.cancel()
        gatewayEventTask = nil
        if let gateway {
            await gateway.disconnect()
        }
        gateway = nil
        gatewayConnected = false
        try? await client.logout()
        KeychainStore.deleteToken()
        ipAuthPollTask?.cancel()
        ipAuthPollTask = nil
        ipAuthTicket = nil
        currentUser = nil
        guilds = []
        privateChannels = []
        messages = [:]
        channelsWithFullHistory = []
        channelsLoadingOlder = []
        readStates = [:]
        typingUsers = [:]
        knownUsers = [:]
        presences = [:]
        relationships = [:]
        myMembers = [:]
        guildMembers = [:]
        slowmodeUntil = [:]
        pinnedDMIds = []
        unreadMarkers = [:]
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

    // MARK: Gateway

    private func connectGateway(token: String) {
        gatewayEventTask?.cancel()
        let gateway = GatewayClient(gatewayURL: instanceConfig.gatewayURL)
        self.gateway = gateway
        gatewayEventTask = Task { [weak self] in
            let events = await gateway.events()
            try? await gateway.connect(token: token)
            for await event in events {
                guard let self else { return }
                await self.handleGatewayEvent(event, token: token)
            }
        }
    }

    private func handleGatewayEvent(_ event: GatewayEvent, token: String) async {
        switch event.name {
        case "READY":
            handleReady(event.data)
        case "RESUMED":
            reconnectAttempts = 0
            gatewayConnected = true
        case "MESSAGE_CREATE":
            guard let message = try? event.data?.decoded(as: Message.self) else { return }
            insert(message)
            bumpLastMessageId(message)
            typingUsers[message.channelId]?[message.author?.id ?? Snowflake(0)] = nil
            if message.channelId == activeChannelId || message.author?.id == currentUser?.id {
                markRead(channelId: message.channelId, messageId: message.id)
            }
        case "MESSAGE_ACK":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let messageId = event.data?["message_id"]?.stringValue.flatMap(Snowflake.init(string:))
            else { return }
            readStates[channelId] = messageId
        case "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let messageId = event.data?["message_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let userId = event.data?["user_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let emoji = try? event.data?["emoji"]?.decoded(as: ReactionEmoji.self)
            else { return }
            applyReactionChange(
                channelId: channelId,
                messageId: messageId,
                emoji: emoji,
                delta: event.name == "MESSAGE_REACTION_ADD" ? 1 : -1,
                byMe: userId == currentUser?.id
            )
        case "PRESENCE_UPDATE":
            applyPresence(event.data)
        case "PRESENCE_UPDATE_BULK":
            for entry in event.data?.arrayValue ?? [] {
                applyPresence(entry)
            }
        case "RELATIONSHIP_ADD", "RELATIONSHIP_UPDATE":
            guard let relationship = try? event.data?.decoded(as: Relationship.self) else { return }
            relationships[relationship.id] = relationship
            if let user = relationship.user {
                knownUsers[user.id] = user
            }
        case "RELATIONSHIP_REMOVE":
            guard let id = event.data?["id"]?.stringValue.flatMap(Snowflake.init(string:)) else { return }
            relationships[id] = nil
        case "TYPING_START":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let userId = event.data?["user_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  userId != currentUser?.id
            else { return }
            typingUsers[channelId, default: [:]][userId] = Date().addingTimeInterval(10)
            Task {
                try? await Task.sleep(for: .seconds(10))
                self.pruneTyping(channelId: channelId)
            }
        case "MESSAGE_UPDATE":
            guard let message = try? event.data?.decoded(as: Message.self) else { return }
            update(message)
        case "MESSAGE_DELETE":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let messageId = event.data?["id"]?.stringValue.flatMap(Snowflake.init(string:))
            else { return }
            messages[channelId]?.removeAll { $0.id == messageId }
        case "GUILD_CREATE":
            guard let readyGuild = try? event.data?.decoded(as: ReadyGuild.self) else { return }
            let guild = readyGuild.asGuild()
            if let index = guilds.firstIndex(where: { $0.id == guild.id }) {
                guilds[index] = guild
            } else {
                guilds.append(guild)
                guilds.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        case "GUILD_DELETE":
            guard let guildId = event.data?["id"]?.stringValue.flatMap(Snowflake.init(string:)) else { return }
            guilds.removeAll { $0.id == guildId }
        case "CHANNEL_CREATE", "CHANNEL_UPDATE":
            guard let channel = try? event.data?.decoded(as: Channel.self) else { return }
            if let guildId = channel.guildId, let index = guilds.firstIndex(where: { $0.id == guildId }) {
                var channels = guilds[index].channels ?? []
                if let existing = channels.firstIndex(where: { $0.id == channel.id }) {
                    channels[existing] = channel
                } else {
                    channels.append(channel)
                }
                guilds[index].channels = channels
            } else if channel.type == .dm || channel.type == .groupDM {
                if let existing = privateChannels.firstIndex(where: { $0.id == channel.id }) {
                    privateChannels[existing] = channel
                } else {
                    privateChannels.insert(channel, at: 0)
                }
            }
        case "CHANNEL_DELETE":
            guard let channel = try? event.data?.decoded(as: Channel.self) else { return }
            if let guildId = channel.guildId, let index = guilds.firstIndex(where: { $0.id == guildId }) {
                guilds[index].channels?.removeAll { $0.id == channel.id }
            }
            privateChannels.removeAll { $0.id == channel.id }
        case GatewayEvent.disconnected:
            gatewayConnected = false
            guard phase == .loggedIn, let gateway else { return }
            reconnectAttempts += 1
            let delay = min(pow(2, Double(reconnectAttempts)), 60)
            try? await Task.sleep(for: .seconds(delay))
            guard phase == .loggedIn else { return }
            try? await gateway.connect(token: token)
        default:
            break
        }
    }

    // MARK: Messages

    private var channelsWithFullHistory: Set<Snowflake> = []
    private var channelsLoadingOlder: Set<Snowflake> = []
    private static let historyPageSize = 50

    func messages(in channelId: Snowflake) -> [Message] {
        messages[channelId] ?? []
    }

    func canLoadOlderMessages(in channelId: Snowflake) -> Bool {
        !channelsWithFullHistory.contains(channelId)
    }

    /// Loads history the first time a channel is opened. Later messages
    /// arrive through the gateway, older pages through loadOlderMessages.
    func loadMessages(for channel: Channel) async {
        guard messages[channel.id] == nil else { return }
        do {
            let history = try await client.messages(in: channel.id, limit: Self.historyPageSize)
            if history.count < Self.historyPageSize {
                channelsWithFullHistory.insert(channel.id)
            }
            // The API returns newest first, the UI wants oldest first.
            messages[channel.id] = history.sorted { $0.id < $1.id }
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Fetches the page before the oldest loaded message and prepends it.
    /// Returns the previous oldest message id so the view can keep its
    /// scroll position anchored there, or nil when nothing was loaded.
    func loadOlderMessages(for channel: Channel) async -> Snowflake? {
        guard let existing = messages[channel.id], let oldest = existing.first else { return nil }
        guard !channelsLoadingOlder.contains(channel.id),
              !channelsWithFullHistory.contains(channel.id)
        else { return nil }
        channelsLoadingOlder.insert(channel.id)
        defer { channelsLoadingOlder.remove(channel.id) }
        do {
            let older = try await client.messages(
                in: channel.id,
                before: oldest.id,
                limit: Self.historyPageSize
            )
            if older.count < Self.historyPageSize {
                channelsWithFullHistory.insert(channel.id)
            }
            guard !older.isEmpty else { return nil }
            let existingIds = Set(existing.map(\.id))
            var merged = existing
            merged.append(contentsOf: older.filter { !existingIds.contains($0.id) })
            merged.sort { $0.id < $1.id }
            messages[channel.id] = merged
            return oldest.id
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    func sendMessage(
        _ content: String,
        in channel: Channel,
        replyTo: Snowflake? = nil,
        files: [APIClient.UploadFile] = []
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        do {
            let sent: Message
            if files.isEmpty {
                sent = try await client.sendMessage(trimmed, to: channel.id, replyTo: replyTo)
            } else {
                sent = try await client.sendMessage(trimmed, to: channel.id, files: files, replyTo: replyTo)
            }
            insert(sent)
            let interval = slowmodeInterval(in: channel)
            if interval > 0 {
                slowmodeUntil[channel.id] = Date().addingTimeInterval(TimeInterval(interval))
            }
        } catch APIError.rateLimited(let retryAfter) {
            if let retryAfter {
                slowmodeUntil[channel.id] = Date().addingTimeInterval(retryAfter)
            }
            lastError = "Slow down, try again in a moment."
        } catch {
            lastError = Self.describe(error)
        }
    }

    func editMessage(_ message: Message, content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let edited = try await client.editMessage(message.id, in: message.channelId, content: trimmed)
            update(edited)
        } catch {
            lastError = Self.describe(error)
        }
    }

    func deleteMessage(_ message: Message) async {
        do {
            try await client.deleteMessage(message.id, in: message.channelId)
            messages[message.channelId]?.removeAll { $0.id == message.id }
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: Reactions

    func toggleReaction(_ emoji: ReactionEmoji, on message: Message) async {
        let mine = message.reactions?.first { $0.emoji.key == emoji.key }?.me == true
        // Optimistic local flip; the gateway event confirms it.
        applyReactionChange(
            channelId: message.channelId,
            messageId: message.id,
            emoji: emoji,
            delta: mine ? -1 : 1,
            byMe: true
        )
        do {
            if mine {
                try await client.removeReaction(emoji, from: message.id, in: message.channelId)
            } else {
                try await client.addReaction(emoji, to: message.id, in: message.channelId)
            }
        } catch {
            applyReactionChange(
                channelId: message.channelId,
                messageId: message.id,
                emoji: emoji,
                delta: mine ? 1 : -1,
                byMe: true
            )
            lastError = Self.describe(error)
        }
    }

    private func applyReactionChange(
        channelId: Snowflake,
        messageId: Snowflake,
        emoji: ReactionEmoji,
        delta: Int,
        byMe: Bool
    ) {
        guard var channelMessages = messages[channelId],
              let index = channelMessages.firstIndex(where: { $0.id == messageId })
        else { return }
        var message = channelMessages[index]
        var reactions = message.reactions ?? []
        if let reactionIndex = reactions.firstIndex(where: { $0.emoji.key == emoji.key }) {
            var reaction = reactions[reactionIndex]
            let alreadyMine = reaction.me == true
            // Skip echoes of changes already applied optimistically.
            if byMe && ((delta > 0 && alreadyMine) || (delta < 0 && !alreadyMine)) { return }
            reaction.count += delta
            if byMe {
                reaction.me = delta > 0
            }
            if reaction.count <= 0 {
                reactions.remove(at: reactionIndex)
            } else {
                reactions[reactionIndex] = reaction
            }
        } else if delta > 0 {
            reactions.append(Reaction(emoji: emoji, count: 1, me: byMe))
        }
        message.reactions = reactions.isEmpty ? nil : reactions
        channelMessages[index] = message
        messages[channelId] = channelMessages
    }

    private func insert(_ message: Message) {
        if let author = message.author {
            knownUsers[author.id] = author
        }
        guard var channelMessages = messages[message.channelId] else { return }
        guard !channelMessages.contains(where: { $0.id == message.id }) else { return }
        channelMessages.append(message)
        channelMessages.sort { $0.id < $1.id }
        messages[message.channelId] = channelMessages
    }

    /// Keeps lastMessageId current on the channel objects so unread
    /// comparisons work without refetching.
    private func bumpLastMessageId(_ message: Message) {
        if let index = privateChannels.firstIndex(where: { $0.id == message.channelId }) {
            privateChannels[index].lastMessageId = message.id
            return
        }
        for guildIndex in guilds.indices {
            if let channelIndex = guilds[guildIndex].channels?.firstIndex(where: { $0.id == message.channelId }) {
                guilds[guildIndex].channels?[channelIndex].lastMessageId = message.id
                return
            }
        }
    }

    // MARK: Read state

    func isUnread(_ channel: Channel) -> Bool {
        guard channel.type != .guildVoice, channel.type != .guildCategory else { return false }
        guard let last = channel.lastMessageId else { return false }
        guard let read = readStates[channel.id] else { return true }
        return last > read
    }

    func hasUnread(_ guild: Guild) -> Bool {
        (guild.channels ?? []).contains { isUnread($0) }
    }

    /// Optimistically records the read position and tells the server.
    func markRead(channelId: Snowflake, messageId: Snowflake) {
        if let current = readStates[channelId], current >= messageId { return }
        readStates[channelId] = messageId
        Task {
            try? await client.ackMessage(messageId, in: channelId)
        }
    }

    func markChannelRead(_ channel: Channel) {
        guard let last = messages(in: channel.id).last?.id ?? channel.lastMessageId else { return }
        markRead(channelId: channel.id, messageId: last)
    }

    /// Applies READY piece by piece so one unexpected field in a section
    /// (or one bad entry in a list) can't take down the whole login.
    private func handleReady(_ data: JSONValue?) {
        guard let data else {
            gatewayLog.error("READY arrived with no data")
            return
        }
        reconnectAttempts = 0
        gatewayConnected = true

        do {
            currentUser = try data["user"]?.decoded(as: User.self) ?? currentUser
        } catch {
            gatewayLog.error("READY user decode failed: \(String(describing: error))")
        }

        var readyGuilds: [ReadyGuild] = []
        for entry in data["guilds"]?.arrayValue ?? [] {
            do {
                readyGuilds.append(try entry.decoded(as: ReadyGuild.self))
            } catch {
                gatewayLog.error("READY guild decode failed: \(String(describing: error))")
            }
        }
        guilds = readyGuilds
            .map { $0.asGuild() }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        privateChannels = (data["private_channels"]?.arrayValue ?? []).compactMap {
            do {
                return try $0.decoded(as: Channel.self)
            } catch {
                gatewayLog.error("READY private channel decode failed: \(String(describing: error))")
                return nil
            }
        }

        for entry in data["read_states"]?.arrayValue ?? [] {
            if let state = try? entry.decoded(as: ReadState.self) {
                readStates[state.id] = state.lastMessageId
            }
        }
        for entry in data["users"]?.arrayValue ?? [] {
            if let user = try? entry.decoded(as: User.self) {
                knownUsers[user.id] = user
            }
        }
        for channel in privateChannels {
            for recipient in channel.recipients ?? [] {
                knownUsers[recipient.id] = recipient
            }
        }
        for entry in data["relationships"]?.arrayValue ?? [] {
            do {
                let relationship = try entry.decoded(as: Relationship.self)
                relationships[relationship.id] = relationship
                if let user = relationship.user {
                    knownUsers[user.id] = user
                }
            } catch {
                gatewayLog.error("READY relationship decode failed: \(String(describing: error))")
            }
        }
        if let myId = currentUser?.id {
            for guild in readyGuilds {
                if let member = guild.members?.first(where: { $0.user?.id == myId }) {
                    myMembers[guild.id] = member
                }
            }
        }
        pinnedDMIds = Set((data["pinned_dms"]?.arrayValue ?? []).compactMap {
            $0.stringValue.flatMap(Snowflake.init(string:))
        })
        sortPrivateChannels()
        applyReadyPresences(data)
        if myStatus != "online", let gateway {
            Task { await gateway.updatePresence(status: myStatus) }
        }
        gatewayLog.info("READY applied: \(self.guilds.count) guilds, \(self.privateChannels.count) DMs, \(self.relationships.count) relationships")
    }

    private func sortPrivateChannels() {
        guard !pinnedDMIds.isEmpty else { return }
        privateChannels.sort { a, b in
            let aPinned = pinnedDMIds.contains(a.id)
            let bPinned = pinnedDMIds.contains(b.id)
            if aPinned != bPinned { return aPinned }
            return (a.lastMessageId ?? a.id) > (b.lastMessageId ?? b.id)
        }
    }

    // MARK: Presence

    /// Reads presences delivered inside READY: a top level array plus one
    /// per guild. Entries carry either user.id or user_id.
    private func applyReadyPresences(_ data: JSONValue?) {
        for entry in data?["presences"]?.arrayValue ?? [] {
            applyPresence(entry)
        }
        for guild in data?["guilds"]?.arrayValue ?? [] {
            for entry in guild["presences"]?.arrayValue ?? [] {
                applyPresence(entry)
            }
        }
    }

    private func applyPresence(_ entry: JSONValue?) {
        guard let entry else { return }
        let userId = entry["user"]?["id"]?.stringValue.flatMap(Snowflake.init(string:))
            ?? entry["user_id"]?.stringValue.flatMap(Snowflake.init(string:))
        guard let userId else { return }
        let status = entry["status"]?.stringValue ?? "offline"
        if status == "offline" {
            presences[userId] = nil
        } else {
            presences[userId] = status
        }
    }

    func presenceStatus(for userId: Snowflake?) -> String? {
        guard let userId else { return nil }
        return presences[userId]
    }

    // MARK: Permissions and slowmode

    /// Effective permissions for the signed-in user in a channel.
    func permissions(in channel: Channel) -> Permissions {
        guard let guildId = channel.guildId else { return .all }
        guard let me = currentUser,
              let guild = guilds.first(where: { $0.id == guildId })
        else { return .all }
        return PermissionCalculator.permissions(
            for: me.id,
            memberRoleIds: myMembers[guildId]?.roles ?? [],
            guild: guild,
            channel: channel
        )
    }

    /// Guild wide permissions, without channel overwrites.
    func guildPermissions(in guildId: Snowflake) -> Permissions {
        guard let me = currentUser,
              let guild = guilds.first(where: { $0.id == guildId })
        else { return [] }
        return PermissionCalculator.permissions(
            for: me.id,
            memberRoleIds: myMembers[guildId]?.roles ?? [],
            guild: guild,
            channel: nil
        )
    }

    func canSendMessages(in channel: Channel) -> Bool {
        permissions(in: channel).contains(.sendMessages)
    }

    func canAttachFiles(in channel: Channel) -> Bool {
        permissions(in: channel).contains(.attachFiles)
    }

    /// Seconds of slowmode that apply to the current user, 0 when exempt.
    func slowmodeInterval(in channel: Channel) -> Int {
        guard let interval = channel.rateLimitPerUser, interval > 0 else { return 0 }
        let perms = permissions(in: channel)
        if perms.contains(.bypassSlowmode) || perms.contains(.manageMessages) || perms.contains(.manageChannels) {
            return 0
        }
        return interval
    }

    func slowmodeRemaining(in channel: Channel) -> TimeInterval {
        guard let until = slowmodeUntil[channel.id] else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    // MARK: Members

    func loadMembers(for guild: Guild) async {
        guard guildMembers[guild.id] == nil else { return }
        do {
            let members = try await client.guildMembers(guild.id, limit: 200)
            for member in members {
                if let user = member.user {
                    knownUsers[user.id] = user
                }
            }
            guildMembers[guild.id] = members.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: Friends

    var friends: [Relationship] {
        relationships.values.filter { $0.type == .friend }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    var pendingRequests: [Relationship] {
        relationships.values
            .filter { $0.type == .incomingRequest || $0.type == .outgoingRequest }
            .sorted { ($0.type.rawValue, $0.id) < ($1.type.rawValue, $1.id) }
    }

    var blockedUsers: [Relationship] {
        relationships.values.filter { $0.type == .blocked }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    func displayName(for relationship: Relationship) -> String {
        relationship.nickname
            ?? relationship.user?.displayName
            ?? knownUsers[relationship.id]?.displayName
            ?? "Unknown"
    }

    func sendFriendRequest(username: String) async -> Bool {
        // Accepts name or name#discriminator.
        let parts = username.split(separator: "#", maxSplits: 1)
        let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let discriminator = parts.count > 1 ? String(parts[1]) : nil
        guard !name.isEmpty else { return false }
        do {
            try await client.sendFriendRequest(username: name, discriminator: discriminator)
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func acceptRequest(_ relationship: Relationship) async {
        do {
            try await client.acceptFriendRequest(from: relationship.id)
        } catch {
            lastError = Self.describe(error)
        }
    }

    func removeRelationship(_ relationship: Relationship) async {
        do {
            try await client.removeRelationship(with: relationship.id)
            relationships[relationship.id] = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Opens (or finds) the DM with a user and returns it for navigation.
    func openDM(with userId: Snowflake) async -> Channel? {
        if let existing = privateChannels.first(where: { channel in
            channel.type == .dm && (channel.recipients ?? []).contains { $0.id == userId }
        }) {
            return existing
        }
        do {
            let channel = try await client.openDM(with: userId)
            if !privateChannels.contains(where: { $0.id == channel.id }) {
                privateChannels.insert(channel, at: 0)
            }
            return channel
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    // MARK: Status

    func setStatus(_ status: String) async {
        myStatus = status
        if let gateway {
            await gateway.updatePresence(status: status)
        }
        if let myId = currentUser?.id {
            presences[myId] = status == "invisible" ? nil : status
        }
    }

    // MARK: Pins and saved messages

    func pinnedMessages(in channel: Channel) async -> [Message] {
        do {
            return try await client.pinnedMessages(in: channel.id)
        } catch {
            lastError = Self.describe(error)
            return []
        }
    }

    func setPinned(_ message: Message, pinned: Bool) async {
        do {
            if pinned {
                try await client.pinMessage(message.id, in: message.channelId)
            } else {
                try await client.unpinMessage(message.id, in: message.channelId)
            }
            var updated = message
            updated.pinned = pinned
            update(updated)
        } catch {
            lastError = Self.describe(error)
        }
    }

    func savedMessages() async -> [Message] {
        do {
            return try await client.savedMessages()
        } catch {
            lastError = Self.describe(error)
            return []
        }
    }

    func setSaved(_ message: Message, saved: Bool) async {
        do {
            if saved {
                try await client.saveMessage(message.id)
            } else {
                try await client.unsaveMessage(message.id)
            }
        } catch {
            lastError = Self.describe(error)
        }
    }

    func recentMentions() async -> [Message] {
        do {
            return try await client.mentions()
        } catch {
            lastError = Self.describe(error)
            return []
        }
    }

    // MARK: Profiles

    func profile(of userId: Snowflake) async -> APIClient.UserProfile? {
        try? await client.profile(of: userId)
    }

    // MARK: Guild membership

    func createInvite(in channel: Channel) async -> String? {
        do {
            return try await client.createInvite(in: channel.id).code
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    /// Joins a guild from an invite code or a full invite link.
    func joinGuild(code rawCode: String) async -> Bool {
        var code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: code), url.host() != nil, let last = url.pathComponents.last, last != "/" {
            code = last
        }
        guard !code.isEmpty else { return false }
        do {
            _ = try await client.acceptInvite(code)
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func createGuild(name: String) async -> Bool {
        do {
            let guild = try await client.createGuild(name: name)
            if !guilds.contains(where: { $0.id == guild.id }) {
                guilds.append(guild)
                guilds.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func leaveGuild(_ guild: Guild) async {
        do {
            try await client.leaveGuild(guild.id)
            guilds.removeAll { $0.id == guild.id }
        } catch {
            lastError = Self.describe(error)
        }
    }

    func kick(_ member: GuildMember, from guildId: Snowflake) async {
        guard let userId = member.user?.id else { return }
        do {
            try await client.kickMember(userId, from: guildId)
            guildMembers[guildId]?.removeAll { $0.user?.id == userId }
        } catch {
            lastError = Self.describe(error)
        }
    }

    func ban(_ member: GuildMember, from guildId: Snowflake) async {
        guard let userId = member.user?.id else { return }
        do {
            try await client.banMember(userId, from: guildId)
            guildMembers[guildId]?.removeAll { $0.user?.id == userId }
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: Pinned DMs

    func isDMPinned(_ channel: Channel) -> Bool {
        pinnedDMIds.contains(channel.id)
    }

    func toggleDMPinned(_ channel: Channel) async {
        let pinned = !pinnedDMIds.contains(channel.id)
        if pinned {
            pinnedDMIds.insert(channel.id)
        } else {
            pinnedDMIds.remove(channel.id)
        }
        sortPrivateChannels()
        try? await client.setDMPinned(channel.id, pinned: pinned)
    }

    // MARK: Unread marker

    /// Captures where the new messages divider belongs, before the open
    /// channel gets acked as read.
    func captureUnreadMarker(_ channel: Channel) {
        if isUnread(channel) {
            unreadMarkers[channel.id] = readStates[channel.id]
        } else {
            unreadMarkers[channel.id] = nil
        }
    }

    // MARK: Emoji

    /// All custom emoji available to the user, grouped by guild.
    var emojiByGuild: [(guild: Guild, emojis: [GuildEmoji])] {
        guilds.compactMap { guild in
            guard let emojis = guild.emojis, !emojis.isEmpty else { return nil }
            return (guild, emojis)
        }
    }

    func customEmoji(id: Snowflake) -> GuildEmoji? {
        for guild in guilds {
            if let emoji = guild.emojis?.first(where: { $0.id == id }) {
                return emoji
            }
        }
        return nil
    }

    // MARK: Sessions

    func authSessions() async -> [APIClient.AuthSession] {
        do {
            return try await client.sessions()
        } catch {
            lastError = Self.describe(error)
            return []
        }
    }

    func revokeSession(_ session: APIClient.AuthSession) async -> Bool {
        do {
            try await client.logoutSessions(idHashes: [session.idHash])
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    // MARK: Guild channel memory

    private static let lastChannelDefaultsKey = "lastChannelByGuild"
    private var lastChannelByGuild: [Snowflake: Snowflake] = {
        let stored = UserDefaults.standard.dictionary(forKey: lastChannelDefaultsKey) as? [String: String] ?? [:]
        var result: [Snowflake: Snowflake] = [:]
        for (guild, channel) in stored {
            if let guildId = Snowflake(string: guild), let channelId = Snowflake(string: channel) {
                result[guildId] = channelId
            }
        }
        return result
    }()

    /// Remembers the channel so the guild reopens there next time.
    func recordVisit(_ channel: Channel) {
        guard let guildId = channel.guildId else { return }
        guard lastChannelByGuild[guildId] != channel.id else { return }
        lastChannelByGuild[guildId] = channel.id
        let stored = lastChannelByGuild.reduce(into: [String: String]()) { result, entry in
            result[entry.key.stringValue] = entry.value.stringValue
        }
        UserDefaults.standard.set(stored, forKey: Self.lastChannelDefaultsKey)
    }

    /// The channel a guild should open on: the last one visited if it still
    /// exists, otherwise the first text channel by position.
    func defaultChannel(for guild: Guild) -> Channel? {
        let channels = guild.channels ?? []
        if let remembered = lastChannelByGuild[guild.id],
           let channel = channels.first(where: { $0.id == remembered }) {
            return channel
        }
        return channels
            .filter { $0.type == .guildText }
            .min { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
    }

    // MARK: Lookups and mentions

    func findChannel(_ id: Snowflake) -> Channel? {
        if let dm = privateChannels.first(where: { $0.id == id }) {
            return dm
        }
        for guild in guilds {
            if let channel = guild.channels?.first(where: { $0.id == id }) {
                return channel
            }
        }
        return nil
    }

    func renderMessageContent(_ content: String) -> AttributedString {
        MessageMarkdown.render(
            content,
            channelName: { self.findChannel($0)?.name },
            userName: { self.knownUsers[$0]?.displayName }
        )
    }

    // MARK: Typing

    func typingNames(in channelId: Snowflake) -> [String] {
        let now = Date()
        let active = (typingUsers[channelId] ?? [:]).filter { $0.value > now }
        return active.keys
            .map { knownUsers[$0]?.displayName ?? "Someone" }
            .sorted()
    }

    private func pruneTyping(channelId: Snowflake) {
        let now = Date()
        typingUsers[channelId] = (typingUsers[channelId] ?? [:]).filter { $0.value > now }
        if typingUsers[channelId]?.isEmpty == true {
            typingUsers[channelId] = nil
        }
    }

    /// Called as the person types; throttled so the server sees at most
    /// one typing ping per channel every eight seconds.
    func composerTyping(in channel: Channel) {
        let now = Date()
        if let last = lastTypingSent[channel.id], now.timeIntervalSince(last) < 8 { return }
        lastTypingSent[channel.id] = now
        Task {
            try? await client.triggerTyping(in: channel.id)
        }
    }

    private func update(_ message: Message) {
        guard var channelMessages = messages[message.channelId] else { return }
        guard let index = channelMessages.firstIndex(where: { $0.id == message.id }) else { return }
        channelMessages[index] = message
        messages[message.channelId] = channelMessages
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case APIError.unauthorized:
            return "Wrong email or password."
        case APIError.rateLimited:
            return "Too many attempts, wait a moment and try again."
        case APIError.httpError(let status, _, let message):
            return message ?? "Server error (\(status))."
        case is URLError:
            return "Could not reach the server. Check your connection."
        default:
            return "Something went wrong: \(error)"
        }
    }
}
