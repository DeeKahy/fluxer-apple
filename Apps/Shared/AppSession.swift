import Foundation
import Observation
import FluxerKit

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

    init() {
        self.client = APIClient()
        if let token = KeychainStore.loadToken() {
            Task { await self.restore(token: token) }
        }
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
        await login(
            email: pending.email,
            password: pending.password,
            captcha: CaptchaSolution(token: token)
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
        let gateway = GatewayClient()
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
            guard let ready = try? event.data?.decoded(as: ReadyPayload.self) else { return }
            reconnectAttempts = 0
            gatewayConnected = true
            currentUser = ready.user
            guilds = ready.guilds
                .map { $0.asGuild() }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            privateChannels = ready.privateChannels ?? []
            for state in ready.readStates ?? [] {
                readStates[state.id] = state.lastMessageId
            }
            for user in ready.users ?? [] {
                knownUsers[user.id] = user
            }
            for channel in privateChannels {
                for recipient in channel.recipients ?? [] {
                    knownUsers[recipient.id] = recipient
                }
            }
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
