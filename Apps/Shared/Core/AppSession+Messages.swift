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
            reportTransient(error)
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
            messages[channel.id] = MessageListOps.mergingOlderPage(older, into: existing)
            return oldest.id
        } catch {
            reportTransient(error)
            return nil
        }
    }

    /// Loads a window of messages centered on a target id, for jumping to a
    /// linked message that isn't in the current window. Returns true when the
    /// target is present in the loaded window afterwards. Errors are swallowed
    /// (some servers may not support the around query) so the caller can fall
    /// back to plain older-history pagination.
    func loadMessagesAround(_ messageId: Snowflake, in channel: Channel) async -> Bool {
        do {
            let window = try await client.messages(
                in: channel.id,
                around: messageId,
                limit: Self.historyPageSize
            )
            guard window.contains(where: { $0.id == messageId }) else { return false }
            messages[channel.id] = window.sorted { $0.id < $1.id }
            // A window is a slice out of the middle: older pages can still load,
            // and re-entering the channel should refetch the newest page since
            // this dropped it from view.
            channelsWithFullHistory.remove(channel.id)
            staleChannels.insert(channel.id)
            scheduleCacheSave()
            return true
        } catch {
            return false
        }
    }

    /// Trending GIFs from the instance provider, empty on failure.
    func trendingGifs() async -> [GifResult] {
        (try? await client.trendingGifs()) ?? []
    }

    /// GIF search results, empty on failure.
    func searchGifs(_ query: String) async -> [GifResult] {
        (try? await client.searchGifs(query)) ?? []
    }

    /// Posts a picked GIF: its media URL becomes the message (rendered inline
    /// as animated media), and the share is registered for provider
    /// attribution. Best effort on the attribution call.
    func sendGif(_ gif: GifResult, in channel: Channel, query: String? = nil, replyTo: Snowflake? = nil) async {
        guard let url = gif.sendURL else { return }
        await sendMessage(url, in: channel, replyTo: replyTo)
        let shareId = gif.shareId
        Task { [client] in try? await client.registerGifShare(id: shareId, query: query) }
    }

    func sendMessage(
        _ content: String,
        in channel: Channel,
        replyTo: Snowflake? = nil,
        files: [APIClient.UploadFile] = []
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return }

        // Optimistic echo for plain text: show the message right away and
        // reconcile with the server copy by nonce. File sends keep the
        // round trip since the placeholder couldn't show the attachments.
        let nonce = String(UInt64.random(in: 1...UInt64.max))
        if files.isEmpty {
            // Replies must carry the referenced message from the start or
            // the placeholder renders as a plain message and the reply
            // preview pops in only when the server copy lands.
            let referenced = replyTo.flatMap { id in
                messages[channel.id]?.first { $0.id == id }
            }
            let placeholder = Message(
                id: placeholderMessageId(in: channel.id),
                channelId: channel.id,
                guildId: channel.guildId,
                author: currentUser,
                content: trimmed,
                timestamp: Date(),
                referencedMessage: referenced.map(IndirectBox.init),
                nonce: nonce
            )
            pendingSends[nonce] = PendingSend(channelId: channel.id, placeholderId: placeholder.id)
            insert(placeholder)
        }

        do {
            let sent: Message
            if files.isEmpty {
                sent = try await client.sendMessage(trimmed, to: channel.id, replyTo: replyTo, nonce: nonce)
            } else {
                sent = try await client.sendMessage(trimmed, to: channel.id, files: files, replyTo: replyTo, nonce: nonce)
            }
            reconcileSend(nonce: nonce, with: sent)
            let interval = slowmodeInterval(in: channel)
            if interval > 0 {
                slowmodeUntil[channel.id] = Date().addingTimeInterval(TimeInterval(interval))
            }
        } catch APIError.rateLimited(let retryAfter) {
            if let retryAfter {
                slowmodeUntil[channel.id] = Date().addingTimeInterval(retryAfter)
            }
            if files.isEmpty {
                failSend(nonce: nonce, content: trimmed, replyTo: replyTo,
                         reason: "Rate limited, try again in a moment.")
            } else {
                reportTransient(message: "Rate limited, try again in a moment.")
            }
        } catch {
            if files.isEmpty {
                failSend(nonce: nonce, content: trimmed, replyTo: replyTo,
                         reason: Self.describe(error))
            } else {
                reportTransient(error)
            }
        }
    }

    /// Moves a pending text send into the failed bucket. Its placeholder
    /// stays in the transcript, greyed out with retry and discard controls,
    /// instead of silently vanishing. If the pending entry is already gone
    /// the gateway echo confirmed the send despite the failed response, so
    /// there is nothing to report.
    private func failSend(nonce: String, content: String, replyTo: Snowflake?, reason: String) {
        guard let pending = pendingSends.removeValue(forKey: nonce) else { return }
        failedSends[nonce] = FailedSend(
            nonce: nonce,
            channelId: pending.channelId,
            placeholderId: pending.placeholderId,
            content: content,
            replyTo: replyTo,
            reason: reason
        )
    }

    /// Resends a failed message, reusing its nonce and placeholder so the
    /// message keeps its spot in the transcript.
    func retrySend(_ failed: FailedSend) async {
        guard failedSends.removeValue(forKey: failed.nonce) != nil else { return }
        pendingSends[failed.nonce] = PendingSend(
            channelId: failed.channelId,
            placeholderId: failed.placeholderId
        )
        do {
            let sent = try await client.sendMessage(
                failed.content,
                to: failed.channelId,
                replyTo: failed.replyTo,
                nonce: failed.nonce
            )
            reconcileSend(nonce: failed.nonce, with: sent)
        } catch APIError.rateLimited(let retryAfter) {
            if let retryAfter {
                slowmodeUntil[failed.channelId] = Date().addingTimeInterval(retryAfter)
            }
            failSend(nonce: failed.nonce, content: failed.content, replyTo: failed.replyTo,
                     reason: "Rate limited, try again in a moment.")
        } catch {
            failSend(nonce: failed.nonce, content: failed.content, replyTo: failed.replyTo,
                     reason: Self.describe(error))
        }
    }

    /// Drops a failed send and its placeholder from the transcript.
    func discardFailedSend(nonce: String) {
        guard let failed = failedSends.removeValue(forKey: nonce) else { return }
        messages[failed.channelId]?.removeAll { $0.id == failed.placeholderId }
    }

    /// The failure record behind a placeholder message, if its send failed.
    func failedSend(for message: Message) -> FailedSend? {
        failedSends.values.first {
            $0.placeholderId == message.id && $0.channelId == message.channelId
        }
    }

    /// A local-only id that sorts right after the newest loaded message, so
    /// the placeholder lands at the bottom regardless of snowflake epochs.
    private func placeholderMessageId(in channelId: Snowflake) -> Snowflake {
        MessageListOps.placeholderId(after: messages[channelId] ?? [])
    }

    /// Swaps a pending placeholder for the server's copy of the message.
    /// Called from both the REST response and the gateway echo; whichever
    /// arrives first wins and the other deduplicates by id. A send marked
    /// failed can still land here when the request went through but its
    /// response never made it back; the echo clears the failed state.
    func reconcileSend(nonce: String, with real: Message) {
        let pending = pendingSends.removeValue(forKey: nonce)
            ?? failedSends.removeValue(forKey: nonce).map {
                PendingSend(channelId: $0.channelId, placeholderId: $0.placeholderId)
            }
        guard let pending else {
            insert(real)
            return
        }
        bumpLastMessageId(real)
        guard let channelMessages = messages[pending.channelId] else { return }
        messages[pending.channelId] = MessageListOps.reconcilingPlaceholder(
            id: pending.placeholderId,
            with: real,
            in: channelMessages
        )
        if let author = real.author {
            knownUsers[author.id] = author
        }
        scheduleCacheSave()
    }

    /// True while a message is a local placeholder still waiting on its
    /// server confirmation, so the view can render it dimmed.
    func isPendingSend(_ message: Message) -> Bool {
        pendingSends.values.contains {
            $0.placeholderId == message.id && $0.channelId == message.channelId
        }
    }

    func editMessage(_ message: Message, content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let edited = try await client.editMessage(message.id, in: message.channelId, content: trimmed)
            update(edited)
        } catch {
            reportTransient(error)
        }
    }

    func deleteMessage(_ message: Message) async {
        do {
            try await client.deleteMessage(message.id, in: message.channelId)
            messages[message.channelId]?.removeAll { $0.id == message.id }
        } catch {
            reportTransient(error)
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
            reportTransient(error)
        }
    }

    func applyReactionChange(
        channelId: Snowflake,
        messageId: Snowflake,
        emoji: ReactionEmoji,
        delta: Int,
        byMe: Bool
    ) {
        guard let channelMessages = messages[channelId] else { return }
        messages[channelId] = MessageListOps.applyingReaction(
            to: channelMessages,
            messageId: messageId,
            emoji: emoji,
            delta: delta,
            byMe: byMe
        )
    }

    func insert(_ message: Message) {
        if let author = message.author {
            knownUsers[author.id] = author
        }
        guard let channelMessages = messages[message.channelId] else { return }
        messages[message.channelId] = MessageListOps.inserting(message, into: channelMessages)
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
        ReadStateOps.isUnread(channel: channel, readStates: readStates, synced: readStatesSynced)
    }

    /// Total for badges tied to the recent-mentions feed. The server bumps
    /// read-state mention counts for every DM message but only records guild
    /// mentions in the recent-mentions history, so a badge summing all
    /// channels shows counts the feed can never display. DMs have their own
    /// badge; the bell only counts guild channels.
    var guildMentionTotal: Int {
        mentionCounts.reduce(0) { total, entry in
            if let channel = findChannel(entry.key),
               channel.type == .dm || channel.type == .groupDM {
                return total
            }
            return total + entry.value
        }
    }

    func hasUnread(_ guild: Guild) -> Bool {
        (guild.channels ?? []).contains { isUnread($0) }
    }

    /// Optimistically records the read position and tells the server.
    func markRead(channelId: Snowflake, messageId: Snowflake) {
        mentionCounts[channelId] = nil
        guard ReadStateOps.shouldAdvance(current: readStates[channelId], to: messageId) else { return }
        readStates[channelId] = messageId
        Task {
            try? await client.ackMessage(messageId, in: channelId)
        }
    }

    func markChannelRead(_ channel: Channel) {
        // The newest loaded message can sit behind the channel's
        // lastMessageId, most commonly when the newest message was deleted:
        // history no longer contains it but lastMessageId still points at
        // it, so acking only messages().last leaves the channel unread
        // forever. Ack the furthest position known, from the live channel
        // object since the one handed in may be a stale copy.
        let live = findChannel(channel.id) ?? channel
        guard let last = ReadStateOps.ackTarget(
            messages(in: channel.id).last?.id,
            live.lastMessageId,
            channel.lastMessageId
        ) else { return }
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
        VoiceStateOps.apply(state, users: &voiceChannelUsers, muted: &voiceMutedUsers)
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
