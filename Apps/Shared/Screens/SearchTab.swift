import SwiftUI
import FluxerKit

struct SearchTab: View {
    @Environment(AppSession.self) private var session

    let openChannel: (Channel) -> Void

    @State private var query = ""
    @State private var messageResults: APIClient.MessageSearchResults?
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !query.isEmpty {
                    results
                } else {
                    Text("Search channels, people, and messages.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .padding(20)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Channels, people, messages")
        .task(id: query) {
            messageResults = nil
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else {
                searching = false
                return
            }
            searching = true
            // Debounce so we only hit the server once typing settles.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await session.searchMessages(trimmed)
            guard !Task.isCancelled else { return }
            messageResults = found
            searching = false
        }
    }

    @ViewBuilder
    private var results: some View {
        let needle = query.lowercased()
        let channels = session.guilds.flatMap { guild in
            (guild.channels ?? [])
                .filter { $0.type == .guildText && ($0.name ?? "").lowercased().contains(needle) }
                .map { (guild, $0) }
        }
        let dms = session.privateChannels.filter { channel in
            (channel.recipients ?? []).contains { $0.displayName.lowercased().contains(needle) }
                || (channel.name ?? "").lowercased().contains(needle)
        }
        let people = matchingPeople(needle)

        if !channels.isEmpty {
            SectionLabel(text: "Channels").padding(12)
            ForEach(channels, id: \.1.id) { pair in
                channelRow(guild: pair.0, channel: pair.1)
            }
        }
        if !dms.isEmpty {
            SectionLabel(text: "Conversations").padding(12)
            ForEach(dms) { channel in
                dmRow(channel)
            }
        }
        if !people.isEmpty {
            SectionLabel(text: "People").padding(12)
            ForEach(people) { user in
                personRow(user)
            }
        }
        messagesSection
        if channels.isEmpty && dms.isEmpty && people.isEmpty
            && (messageResults?.messages.isEmpty ?? true) && !searching {
            Text("Nothing matches \"\(query)\"")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .padding(20)
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        if searching {
            HStack {
                Spacer()
                ProgressView().tint(Theme.muted)
                Spacer()
            }
            .padding(16)
        } else if let results = messageResults {
            if results.indexing {
                Text("The server is still indexing messages, try again in a bit.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .padding(20)
            } else if !results.messages.isEmpty {
                SectionLabel(text: results.total > results.messages.count
                    ? "Messages (\(results.total))" : "Messages").padding(12)
                ForEach(results.messages) { message in
                    messageRow(message, resultChannels: results.channels)
                }
            }
        }
    }

    private func matchingPeople(_ needle: String) -> [User] {
        session.knownUsers.values
            .filter { user in
                user.id != session.currentUser?.id
                    && (user.displayName.lowercased().contains(needle)
                        || (user.username ?? "").lowercased().contains(needle))
            }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
            .prefix(15)
            .map { $0 }
    }

    private func channelRow(guild: Guild, channel: Channel) -> some View {
        Button {
            openChannel(channel)
        } label: {
            HStack(spacing: 10) {
                Text("#").foregroundStyle(Theme.faint).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name ?? "channel")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.rowText)
                    Text(guild.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableRowStyle())
    }

    private func dmRow(_ channel: Channel) -> some View {
        Button {
            openChannel(channel)
        } label: {
            HStack(spacing: 10) {
                let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
                AvatarView(user: other, diameter: 30)
                Text((channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
                    .map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.rowText)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableRowStyle())
    }

    private func personRow(_ user: User) -> some View {
        Button {
            Task {
                if let dm = await session.openDM(with: user.id) {
                    openChannel(dm)
                }
            }
        } label: {
            HStack(spacing: 10) {
                AvatarView(user: user, diameter: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.displayName)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.rowText)
                    Text(user.username ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableRowStyle())
    }

    private func messageRow(_ message: Message, resultChannels: [Channel]) -> some View {
        let channel = session.findChannel(message.channelId)
            ?? resultChannels.first { $0.id == message.channelId }
        return Button {
            if let channel {
                openChannel(channel)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(user: message.author, diameter: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.author?.displayName ?? "Unknown")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.rowText)
                        if let name = channel?.name {
                            Text("#\(name)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                        if let timestamp = message.timestamp {
                            Text(DMsTab.shortTime(timestamp))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    if let content = message.content, !content.isEmpty {
                        Text(content)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.soft)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    } else if message.attachments?.isEmpty == false {
                        Label("Attachment", systemImage: "paperclip")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableRowStyle())
    }
}
