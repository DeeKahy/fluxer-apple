import Foundation
import FluxerKit

extension AppSession {
    // MARK: Messages

    static let historyPageSize = 50

    func messages(in channelId: Snowflake) -> [Message] {
        messages[channelId] ?? []
    }

    func canLoadOlderMessages(in channelId: Snowflake) -> Bool {
        !channelsWithFullHistory.contains(channelId)
    }

    /// Loads history the first time a channel is opened, and re-fetches
    /// the newest page for channels whose content is cache-stale, so gaps
    /// from offline time or reconnects can't survive. Later messages
    /// arrive through the gateway, older pages through loadOlderMessages.
    func loadMessages(for channel: Channel) async {
        if messages[channel.id] != nil && !staleChannels.contains(channel.id) { return }
        do {
            let history = try await client.messages(in: channel.id, limit: Self.historyPageSize)
            if history.count < Self.historyPageSize {
                channelsWithFullHistory.insert(channel.id)
            } else {
                channelsWithFullHistory.remove(channel.id)
            }
            // The API returns newest first, the UI wants oldest first.
            // Replacing wholesale removes any hole between cached history
            // and the present; older pages refetch on scroll.
            messages[channel.id] = history.sorted { $0.id < $1.id }
            staleChannels.remove(channel.id)
            scheduleCacheSave()
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

    func applyReactionChange(
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

    func insert(_ message: Message) {
        if let author = message.author {
            knownUsers[author.id] = author
        }
        guard var channelMessages = messages[message.channelId] else { return }
        guard !channelMessages.contains(where: { $0.id == message.id }) else { return }
        channelMessages.append(message)
        channelMessages.sort { $0.id < $1.id }
        messages[message.channelId] = channelMessages
        scheduleCacheSave()
    }

    /// Keeps lastMessageId current on the channel objects so unread
    /// comparisons work without refetching.
    func bumpLastMessageId(_ message: Message) {
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
        // Until READY brings real read states, a missing entry means
        // "unknown", not "unread". Claiming unread here made every cached
        // DM light up with a badge during connect.
        guard readStatesSynced else { return false }
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
        mentionCounts[channelId] = nil
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
    func handleReady(_ data: JSONValue?) {
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
                if let mentions = state.mentionCount, mentions > 0 {
                    mentionCounts[state.id] = mentions
                } else {
                    mentionCounts[state.id] = nil
                }
            }
        }
        readStatesSynced = true
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
        voiceChannelUsers = [:]
        voiceMutedUsers = []
        for guildEntry in data["guilds"]?.arrayValue ?? [] {
            for entry in guildEntry["voice_states"]?.arrayValue ?? [] {
                if let state = try? entry.decoded(as: VoiceState.self) {
                    applyVoiceState(state)
                }
            }
        }
        // A new session means the gateway replayed nothing: everything
        // loaded before is suspect until refetched.
        staleChannels.formUnion(messages.keys)
        if let activeId = activeChannelId, let activeChannel = findChannel(activeId) {
            Task { await loadMessages(for: activeChannel) }
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

    /// Fires a native notification for DMs and mentions from others.
    func notifyIfNeeded(_ message: Message, raw: JSONValue?) {
        guard let myId = currentUser?.id, message.author?.id != myId else { return }
        guard let channel = findChannel(message.channelId) else { return }
        let isDM = channel.type == .dm || channel.type == .groupDM
        let mentioned = (raw?["mentions"]?.arrayValue ?? []).contains {
            $0["id"]?.stringValue == myId.stringValue
        } || raw?["mention_everyone"]?.boolValue == true
        let title = channel.name.map { "#\($0)" }
            ?? (channel.recipients ?? []).filter { $0.id != myId }.map(\.displayName).joined(separator: ", ")
        if mentioned && activeChannelId != message.channelId {
            mentionCounts[message.channelId, default: 0] += 1
        }
        NotificationManager.shared.notifyMessage(
            message,
            channelTitle: title,
            isDM: isDM,
            mentionsMe: mentioned,
            isActiveChannel: activeChannelId == message.channelId
        )
    }

    /// Dock and app icon badge: unread direct conversations.
    func updateBadge() {
        let unreadDMs = privateChannels.filter { isUnread($0) }.count
        NotificationManager.shared.updateBadge(unreadCount: unreadDMs)
    }

    /// Moves a user between voice channel occupancy sets and keeps their
    /// mute badge current.
    func applyVoiceState(_ state: VoiceState) {
        for (channelId, users) in voiceChannelUsers where users.contains(state.userId) {
            voiceChannelUsers[channelId]?.remove(state.userId)
            if voiceChannelUsers[channelId]?.isEmpty == true {
                voiceChannelUsers[channelId] = nil
            }
        }
        if let channelId = state.channelId {
            voiceChannelUsers[channelId, default: []].insert(state.userId)
            if state.isMuted {
                voiceMutedUsers.insert(state.userId)
            } else {
                voiceMutedUsers.remove(state.userId)
            }
        } else {
            voiceMutedUsers.remove(state.userId)
        }
    }

    func sortPrivateChannels() {
        guard !pinnedDMIds.isEmpty else { return }
        privateChannels.sort { a, b in
            let aPinned = pinnedDMIds.contains(a.id)
            let bPinned = pinnedDMIds.contains(b.id)
            if aPinned != bPinned { return aPinned }
            return (a.lastMessageId ?? a.id) > (b.lastMessageId ?? b.id)
        }
    }
}
