import SwiftUI
import FluxerKit

struct ChannelListView: View {
    let guild: Guild
    @Binding var selectedChannel: Channel?

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
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                Section(section.category?.name ?? "") {
                    ForEach(section.channels) { channel in
                        Button {
                            selectedChannel = channel
                        } label: {
                            Label(channel.name ?? "channel", systemImage: "number")
                                .foregroundStyle(selectedChannel?.id == channel.id ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(guild.name)
    }
}
