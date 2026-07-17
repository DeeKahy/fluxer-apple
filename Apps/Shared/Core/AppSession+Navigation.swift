import Foundation
import FluxerKit

extension AppSession {
    // MARK: Guild channel memory

    static let lastChannelDefaultsKey = "lastChannelByGuild"

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

    func pruneTyping(channelId: Snowflake) {
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

    func update(_ message: Message) {
        guard var channelMessages = messages[message.channelId] else { return }
        guard let index = channelMessages.firstIndex(where: { $0.id == message.id }) else { return }
        channelMessages[index] = message
        messages[message.channelId] = channelMessages
    }

    static func describe(_ error: any Error) -> String {
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
