import Foundation
import FluxerKit

extension AppSession {
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


    func inviteInfo(code: String) async -> APIClient.Invite? {
        if let cached = inviteCache[code] {
            return cached
        }
        let info = try? await client.inviteInfo(code)
        inviteCache[code] = .some(info)
        return info
    }

    func isMember(ofGuild guildId: Snowflake) -> Bool {
        guilds.contains { $0.id == guildId }
    }

    /// Accepts an invite and navigates there once the guild arrives.
    func joinAndJump(code: String) async {
        guard await joinGuild(code: code) else { return }
        let info = inviteCache[code].flatMap { $0 }
        // The guild lands via GUILD_CREATE; give it a moment.
        for _ in 0..<10 {
            if let guildId = info?.guild?.id,
               let guild = guilds.first(where: { $0.id == guildId }) {
                let inviteChannelId = info?.channel?.id
                let target = guild.channels?.first { $0.id == inviteChannelId }
                    ?? defaultChannel(for: guild)
                if let target {
                    channelJump = target
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
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

    // MARK: Calls

    /// Joins voice on a DM channel, then rings once the call exists.
    /// Ringing before the room connects is rejected by the server.
    func startCall(in channel: Channel) async {
        voice.onConnected = { [weak self] in
            Task { try? await self?.client.ringCall(in: channel.id) }
        }
        voice.onCallAnswered = { [weak self] in
            Task { try? await self?.client.stopRinging(in: channel.id) }
        }
        await voice.join(channelId: channel.id, guildId: channel.guildId, ringing: true)
    }

    func acceptIncomingCall() async {
        guard let channel = incomingCall else { return }
        incomingCall = nil
        await voice.join(channelId: channel.id, guildId: channel.guildId)
    }

    func declineIncomingCall() async {
        guard let channel = incomingCall else { return }
        incomingCall = nil
        if let myId = currentUser?.id {
            try? await client.stopRinging(in: channel.id, recipients: [myId])
        }
    }

    func joinVoice(_ channel: Channel) async {
        await voice.join(channelId: channel.id, guildId: channel.guildId)
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
}
