import Foundation
import Testing
@testable import FluxerKit

private func decodeFixture<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder.fluxer.decode(T.self, from: Data(json.utf8))
}

private func msg(
    _ id: UInt64,
    channel: UInt64 = 1,
    author: UInt64? = nil,
    content: String = "",
    reactions: [Reaction]? = nil
) -> Message {
    Message(
        id: Snowflake(id),
        channelId: Snowflake(channel),
        author: author.map { decodeFixture(User.self, "{\"id\": \"\($0)\", \"username\": \"u\($0)\"}") },
        content: content,
        reactions: reactions
    )
}

private func voiceState(
    user: UInt64,
    channel: UInt64?,
    selfMute: Bool? = nil,
    mute: Bool? = nil
) -> VoiceState {
    var fields = ["\"user_id\": \"\(user)\""]
    fields.append("\"channel_id\": \(channel.map { "\"\($0)\"" } ?? "null")")
    if let selfMute { fields.append("\"self_mute\": \(selfMute)") }
    if let mute { fields.append("\"mute\": \(mute)") }
    return decodeFixture(VoiceState.self, "{\(fields.joined(separator: ", "))}")
}

@Suite("MessageListOps: insert and merge")
struct MessageListInsertTests {
    @Test func insertKeepsAscendingOrder() {
        let list = [msg(10), msg(30)]
        let result = MessageListOps.inserting(msg(20), into: list)
        #expect(result.map(\.id.rawValue) == [10, 20, 30])
    }

    @Test func insertDropsDuplicatesById() {
        let list = [msg(10), msg(20)]
        let result = MessageListOps.inserting(msg(20, content: "changed"), into: list)
        #expect(result.count == 2)
        #expect(result[1].content == "")
    }

    @Test func olderPageMergesBeforeExistingAndDedups() {
        let loaded = [msg(50), msg(60)]
        let older = [msg(40), msg(30), msg(50)]
        let result = MessageListOps.mergingOlderPage(older, into: loaded)
        #expect(result.map(\.id.rawValue) == [30, 40, 50, 60])
    }
}

@Suite("MessageListOps: optimistic send reconcile")
struct ReconcileTests {
    @Test func placeholderIdSortsAfterNewestMessage() {
        let list = [msg(100), msg(200)]
        #expect(MessageListOps.placeholderId(after: list) == Snowflake(201))
    }

    @Test func placeholderIdInEmptyChannelIsNonZero() {
        #expect(MessageListOps.placeholderId(after: []) == Snowflake(2))
    }

    @Test func restResponseSwapsPlaceholderInPlace() {
        let placeholder = msg(201, content: "hi")
        let list = [msg(200), placeholder]
        let real = msg(500, content: "hi")
        let result = MessageListOps.reconcilingPlaceholder(id: placeholder.id, with: real, in: list)
        #expect(result.map(\.id.rawValue) == [200, 500])
    }

    @Test func gatewayEchoWinnerMakesLoserDropPlaceholder() {
        // The gateway echo already inserted the real message; when the REST
        // response reconciles the same nonce the placeholder must go away
        // without duplicating the real copy.
        let placeholder = msg(201, content: "hi")
        let real = msg(500, content: "hi")
        let list = [msg(200), placeholder, real]
        let result = MessageListOps.reconcilingPlaceholder(id: placeholder.id, with: real, in: list)
        #expect(result.map(\.id.rawValue) == [200, 500])
    }

    @Test func missingPlaceholderFallsBackToDedupedInsert() {
        let real = msg(500)
        let list = [msg(200)]
        let result = MessageListOps.reconcilingPlaceholder(id: Snowflake(999), with: real, in: list)
        #expect(result.map(\.id.rawValue) == [200, 500])
        let again = MessageListOps.reconcilingPlaceholder(id: Snowflake(999), with: real, in: result)
        #expect(again.count == 2)
    }

    @Test func swapKeepsListSortedWhenServerIdIsOlderThanNeighbors() {
        // The placeholder id is a guess; the server's real snowflake can
        // land below a message that arrived from someone else meanwhile.
        let placeholder = msg(601, content: "mine")
        let list = [msg(300), msg(600), placeholder]
        let real = msg(400, content: "mine")
        let result = MessageListOps.reconcilingPlaceholder(id: placeholder.id, with: real, in: list)
        #expect(result.map(\.id.rawValue) == [300, 400, 600])
    }
}

@Suite("MessageListOps: reactions")
struct ReactionTests {
    private let thumbsUp = ReactionEmoji(name: "\u{1F44D}")
    private let fire = ReactionEmoji(name: "\u{1F525}")

    @Test func addingFirstReactionCreatesPill() {
        let list = [msg(10)]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: thumbsUp, delta: 1, byMe: true
        )
        let reaction = result[0].reactions?.first
        #expect(reaction?.count == 1)
        #expect(reaction?.me == true)
    }

    @Test func someoneElseIncrementsWithoutClaimingMine() {
        let list = [msg(10, reactions: [Reaction(emoji: thumbsUp, count: 1, me: true)])]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: thumbsUp, delta: 1, byMe: false
        )
        let reaction = result[0].reactions?.first
        #expect(reaction?.count == 2)
        #expect(reaction?.me == true)
    }

    @Test func gatewayEchoOfOwnOptimisticAddIsSkipped() {
        // The local toggle already set count 1 me true; the echo of that
        // same add must not double count.
        let list = [msg(10, reactions: [Reaction(emoji: thumbsUp, count: 1, me: true)])]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: thumbsUp, delta: 1, byMe: true
        )
        #expect(result[0].reactions?.first?.count == 1)
    }

    @Test func gatewayEchoOfOwnOptimisticRemoveIsSkipped() {
        let list = [msg(10, reactions: [Reaction(emoji: thumbsUp, count: 1, me: false)])]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: thumbsUp, delta: -1, byMe: true
        )
        #expect(result[0].reactions?.first?.count == 1)
    }

    @Test func removingLastReactionDropsThePill() {
        let list = [msg(10, reactions: [Reaction(emoji: thumbsUp, count: 1, me: true)])]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: thumbsUp, delta: -1, byMe: true
        )
        #expect(result[0].reactions == nil)
    }

    @Test func removeForUnknownEmojiIsIgnored() {
        let list = [msg(10, reactions: [Reaction(emoji: thumbsUp, count: 2, me: false)])]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: fire, delta: -1, byMe: false
        )
        #expect(result[0].reactions?.count == 1)
        #expect(result[0].reactions?.first?.count == 2)
    }

    @Test func unknownMessageIsIgnored() {
        let list = [msg(10)]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(99), emoji: thumbsUp, delta: 1, byMe: false
        )
        #expect(result[0].reactions == nil)
    }

    @Test func customEmojiKeyedById() {
        let custom = ReactionEmoji(id: Snowflake(777), name: "blob")
        let renamed = ReactionEmoji(id: Snowflake(777), name: "blob")
        let list = [msg(10, reactions: [Reaction(emoji: custom, count: 1, me: false)])]
        let result = MessageListOps.applyingReaction(
            to: list, messageId: Snowflake(10), emoji: renamed, delta: 1, byMe: false
        )
        #expect(result[0].reactions?.count == 1)
        #expect(result[0].reactions?.first?.count == 2)
    }
}

@Suite("ReadStateOps")
struct ReadStateOpsTests {
    private func channel(_ id: UInt64, last: UInt64?, type: Channel.Kind = .guildText) -> Channel {
        let lastField = last.map { ", \"last_message_id\": \"\($0)\"" } ?? ""
        return decodeFixture(
            Channel.self,
            "{\"id\": \"\(id)\", \"type\": \(type.rawValue)\(lastField)}"
        )
    }

    @Test func unreadWhenLastMessagePassesReadPosition() {
        let target = channel(1, last: 100)
        #expect(ReadStateOps.isUnread(channel: target, readStates: [Snowflake(1): Snowflake(50)], synced: true))
        #expect(!ReadStateOps.isUnread(channel: target, readStates: [Snowflake(1): Snowflake(100)], synced: true))
    }

    @Test func missingReadStateMeansUnreadOnlyAfterSync() {
        let target = channel(1, last: 100)
        #expect(ReadStateOps.isUnread(channel: target, readStates: [:], synced: true))
        // Before READY delivers read states, "no entry" is unknown, not
        // unread; the cached channel list must not light up.
        #expect(!ReadStateOps.isUnread(channel: target, readStates: [:], synced: false))
    }

    @Test func channelsWithoutMessagesOrChatAreNeverUnread() {
        #expect(!ReadStateOps.isUnread(channel: channel(1, last: nil), readStates: [:], synced: true))
        #expect(!ReadStateOps.isUnread(
            channel: channel(1, last: 100, type: .guildCategory), readStates: [:], synced: true
        ))
        #expect(!ReadStateOps.isUnread(
            channel: channel(1, last: 100, type: .guildVoice), readStates: [:], synced: true
        ))
    }

    @Test func ackTargetPicksFurthestKnownPosition() {
        // lastMessageId can dangle past a deleted newest message; the ack
        // must use it or the channel stays unread forever.
        #expect(ReadStateOps.ackTarget(Snowflake(90), Snowflake(120), nil) == Snowflake(120))
        #expect(ReadStateOps.ackTarget(nil, nil, nil) == nil)
    }

    @Test func readPositionNeverMovesBackwards() {
        #expect(ReadStateOps.shouldAdvance(current: nil, to: Snowflake(10)))
        #expect(ReadStateOps.shouldAdvance(current: Snowflake(5), to: Snowflake(10)))
        #expect(!ReadStateOps.shouldAdvance(current: Snowflake(10), to: Snowflake(10)))
        #expect(!ReadStateOps.shouldAdvance(current: Snowflake(20), to: Snowflake(10)))
    }
}

@Suite("VoiceStateOps")
struct VoiceStateOpsTests {
    @Test func joinMoveAndLeaveKeepOccupancyConsistent() {
        var users: [Snowflake: Set<Snowflake>] = [:]
        var muted: Set<Snowflake> = []
        let dee = Snowflake(1)

        VoiceStateOps.apply(
            voiceState(user: 1, channel: 10), users: &users, muted: &muted
        )
        #expect(users[Snowflake(10)] == [dee])

        VoiceStateOps.apply(
            voiceState(user: 1, channel: 20), users: &users, muted: &muted
        )
        #expect(users[Snowflake(10)] == nil)
        #expect(users[Snowflake(20)] == [dee])

        VoiceStateOps.apply(
            voiceState(user: 1, channel: nil), users: &users, muted: &muted
        )
        #expect(users.isEmpty)
    }

    @Test func muteBadgeTracksSelfAndServerMute() {
        var users: [Snowflake: Set<Snowflake>] = [:]
        var muted: Set<Snowflake> = []
        let dee = Snowflake(1)

        VoiceStateOps.apply(
            voiceState(user: 1, channel: 10, selfMute: true),
            users: &users, muted: &muted
        )
        #expect(muted.contains(dee))

        VoiceStateOps.apply(
            voiceState(user: 1, channel: 10, selfMute: false),
            users: &users, muted: &muted
        )
        #expect(!muted.contains(dee))

        VoiceStateOps.apply(
            voiceState(user: 1, channel: 10, selfMute: false, mute: true),
            users: &users, muted: &muted
        )
        #expect(muted.contains(dee))
    }

    @Test func leavingVoiceClearsTheMuteBadge() {
        var users: [Snowflake: Set<Snowflake>] = [:]
        var muted: Set<Snowflake> = []
        let dee = Snowflake(1)
        VoiceStateOps.apply(
            voiceState(user: 1, channel: 10, selfMute: true),
            users: &users, muted: &muted
        )
        VoiceStateOps.apply(
            voiceState(user: 1, channel: nil), users: &users, muted: &muted
        )
        #expect(muted.isEmpty)
    }

    @Test func otherOccupantsSurviveSomeoneLeaving() {
        var users: [Snowflake: Set<Snowflake>] = [:]
        var muted: Set<Snowflake> = []
        VoiceStateOps.apply(
            voiceState(user: 1, channel: 10), users: &users, muted: &muted
        )
        VoiceStateOps.apply(
            voiceState(user: 2, channel: 10), users: &users, muted: &muted
        )
        VoiceStateOps.apply(
            voiceState(user: 1, channel: nil), users: &users, muted: &muted
        )
        #expect(users[Snowflake(10)] == [Snowflake(2)])
    }
}
