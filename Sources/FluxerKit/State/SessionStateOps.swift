import Foundation

// Pure state transitions behind the app's message list, read state, and
// voice occupancy bookkeeping. AppSession delegates the tricky math here
// so swift test can cover it without SwiftUI or a live connection.

public enum MessageListOps {
    /// Appends a message, dropping duplicates by id and keeping the list
    /// in ascending id order.
    public static func inserting(_ message: Message, into list: [Message]) -> [Message] {
        guard !list.contains(where: { $0.id == message.id }) else { return list }
        var result = list
        result.append(message)
        result.sort { $0.id < $1.id }
        return result
    }

    /// Merges an older history page into the loaded list, deduplicated
    /// against what is already there.
    public static func mergingOlderPage(_ older: [Message], into list: [Message]) -> [Message] {
        let existingIds = Set(list.map(\.id))
        var merged = list
        merged.append(contentsOf: older.filter { !existingIds.contains($0.id) })
        merged.sort { $0.id < $1.id }
        return merged
    }

    /// A local-only id for an optimistic placeholder that sorts right after
    /// the newest loaded message, regardless of the server's snowflake epoch.
    public static func placeholderId(after list: [Message]) -> Snowflake {
        let newest = list.last?.id.rawValue ?? 0
        return Snowflake(max(newest, 1) &+ 1)
    }

    /// Swaps a pending placeholder for the server's copy of the message.
    /// If the server copy already landed (the gateway echo won the race)
    /// the placeholder is dropped; if the placeholder is gone the server
    /// copy is inserted with the usual dedup.
    public static func reconcilingPlaceholder(
        id placeholderId: Snowflake,
        with real: Message,
        in list: [Message]
    ) -> [Message] {
        guard let index = list.firstIndex(where: { $0.id == placeholderId }) else {
            return inserting(real, into: list)
        }
        var result = list
        if result.contains(where: { $0.id == real.id }) {
            result.remove(at: index)
        } else {
            result[index] = real
            result.sort { $0.id < $1.id }
        }
        return result
    }

    /// Applies a reaction count change to a message, skipping gateway
    /// echoes of changes that were already applied optimistically.
    public static func applyingReaction(
        to list: [Message],
        messageId: Snowflake,
        emoji: ReactionEmoji,
        delta: Int,
        byMe: Bool
    ) -> [Message] {
        guard let index = list.firstIndex(where: { $0.id == messageId }) else { return list }
        var message = list[index]
        var reactions = message.reactions ?? []
        if let reactionIndex = reactions.firstIndex(where: { $0.emoji.key == emoji.key }) {
            var reaction = reactions[reactionIndex]
            let alreadyMine = reaction.me == true
            // An echo of our own optimistic flip arrives with the state
            // already applied; applying it again would double count.
            if byMe && ((delta > 0 && alreadyMine) || (delta < 0 && !alreadyMine)) { return list }
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
        } else {
            return list
        }
        message.reactions = reactions.isEmpty ? nil : reactions
        var result = list
        result[index] = message
        return result
    }
}

public enum ReadStateOps {
    /// Whether a channel should render as unread. Before read states have
    /// synced from READY a missing entry means "unknown", not "unread",
    /// or every cached conversation lights up during connect.
    public static func isUnread(
        channel: Channel,
        readStates: [Snowflake: Snowflake],
        synced: Bool
    ) -> Bool {
        guard synced else { return false }
        guard channel.type != .guildVoice, channel.type != .guildCategory else { return false }
        guard let last = channel.lastMessageId else { return false }
        guard let read = readStates[channel.id] else { return true }
        return last > read
    }

    /// The furthest known read position to ack. lastMessageId can point at
    /// a deleted message that history no longer contains, so acking only
    /// the newest loaded message would leave the channel unread forever.
    public static func ackTarget(_ positions: Snowflake?...) -> Snowflake? {
        positions.compactMap { $0 }.max()
    }

    /// Whether a stored read position should advance to the given id.
    public static func shouldAdvance(current: Snowflake?, to messageId: Snowflake) -> Bool {
        guard let current else { return true }
        return messageId > current
    }
}

public enum VoiceStateOps {
    /// Moves a user between voice channel occupancy sets and keeps their
    /// mute badge current. A nil channel means they left voice entirely.
    public static func apply(
        _ state: VoiceState,
        users: inout [Snowflake: Set<Snowflake>],
        muted: inout Set<Snowflake>
    ) {
        for (channelId, occupants) in users where occupants.contains(state.userId) {
            users[channelId]?.remove(state.userId)
            if users[channelId]?.isEmpty == true {
                users[channelId] = nil
            }
        }
        if let channelId = state.channelId {
            users[channelId, default: []].insert(state.userId)
            if state.isMuted {
                muted.insert(state.userId)
            } else {
                muted.remove(state.userId)
            }
        } else {
            muted.remove(state.userId)
        }
    }
}
