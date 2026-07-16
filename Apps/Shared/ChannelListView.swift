import SwiftUI
import FluxerKit

/// Channels of one guild, grouped by category. With a selection binding the
/// rows drive a split view; without one they push onto a navigation stack.
struct ChannelListView: View {
    let guild: Guild
    var selectedChannel: Binding<Channel?>?

    init(guild: Guild, selectedChannel: Binding<Channel?>? = nil) {
        self.guild = guild
        self.selectedChannel = selectedChannel
    }

    private var sections: [(category: Channel?, channels: [Channel])] {
        let all = (guild.channels ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
        let categories = all.filter { $0.type == .guildCategory }
        let textChannels = all.filter { $0.type == .guildText }
        var grouped: [(Channel?, [Channel])] = []
        let uncategorized = textChannels.filter { channel in
            channel.parentId == nil || !categories.contains { $0.id == channel.parentId }
        }
        if !uncategorized.isEmpty {
            grouped.append((nil, uncategorized))
        }
        for category in categories {
            let children = textChannels.filter { $0.parentId == category.id }
            if !children.isEmpty {
                grouped.append((category, children))
            }
        }
        return grouped
    }

    var body: some View {
        List {
            if sections.isEmpty {
                Text("No text channels")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                Section(section.category?.name ?? "") {
                    ForEach(section.channels) { channel in
                        row(for: channel)
                    }
                }
            }
        }
        .navigationTitle(guild.name)
    }

    @ViewBuilder
    private func row(for channel: Channel) -> some View {
        let label = Label(channel.name ?? "channel", systemImage: "number")
        if let selectedChannel {
            Button {
                selectedChannel.wrappedValue = channel
            } label: {
                label
                    .foregroundStyle(
                        selectedChannel.wrappedValue?.id == channel.id ? Color.accentColor : Color.primary
                    )
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: channel) {
                label
            }
        }
    }
}
