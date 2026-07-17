import Foundation
import FluxerKit

extension AppSession {
    // MARK: Gateway

    func connectGateway(token: String) {
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

    func handleGatewayEvent(_ event: GatewayEvent, token: String) async {
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
            notifyIfNeeded(message, raw: event.data)
            updateBadge()
        case "MESSAGE_ACK":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let messageId = event.data?["message_id"]?.stringValue.flatMap(Snowflake.init(string:))
            else { return }
            readStates[channelId] = messageId
            updateBadge()
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
        case "CALL_CREATE", "CALL_UPDATE":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)),
                  let myId = currentUser?.id
            else { return }
            let ringing = (event.data?["ringing"]?.arrayValue ?? [])
                .compactMap { $0.stringValue.flatMap(Snowflake.init(string:)) }
            for entry in event.data?["voice_states"]?.arrayValue ?? [] {
                if let state = try? entry.decoded(as: VoiceState.self) {
                    applyVoiceState(state)
                }
            }
            if ringing.contains(myId), voice.connectedChannelId != channelId {
                let channel = findChannel(channelId)
                incomingCall = channel
                let caller = (channel?.recipients ?? []).first { $0.id != myId }
                NotificationManager.shared.notifyIncomingCall(
                    from: caller?.displayName ?? channel?.name ?? "Fluxer",
                    channelId: channelId
                )
            } else if incomingCall?.id == channelId {
                incomingCall = nil
                NotificationManager.shared.clearCallNotification(channelId: channelId)
            }
        case "CALL_DELETE":
            guard let channelId = event.data?["channel_id"]?.stringValue.flatMap(Snowflake.init(string:)) else { return }
            if incomingCall?.id == channelId {
                incomingCall = nil
            }
            NotificationManager.shared.clearCallNotification(channelId: channelId)
        case "VOICE_SERVER_UPDATE":
            guard let update = try? event.data?.decoded(as: VoiceServerUpdate.self) else {
                gatewayLog.error("VOICE_SERVER_UPDATE decode failed")
                return
            }
            await voice.handleServerUpdate(update)
        case "VOICE_STATE_UPDATE":
            guard let state = try? event.data?.decoded(as: VoiceState.self) else { return }
            applyVoiceState(state)
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
}
