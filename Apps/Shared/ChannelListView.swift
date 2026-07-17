import SwiftUI
import FluxerKit

/// Channels of one guild, grouped by category. With a selection binding the
/// rows drive a split view; without one they push onto a navigation stack.
struct ChannelListView: View {
    @Environment(AppSession.self) private var session

    let guild: Guild
    var selectedChannel: Binding<Channel?>?

    @State private var inviteCode: String?

    init(guild: Guild, selectedChannel: Binding<Channel?>? = nil) {
        self.guild = guild
        self.selectedChannel = selectedChannel
    }

    private var sections: [(category: Channel?, channels: [Channel])] {
        let all = (guild.channels ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
        let categories = all.filter { $0.type == .guildCategory }
        let textChannels = all.filter { $0.type == .guildText || $0.type == .guildVoice }
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
        .alert(
            "Invite created",
            isPresented: Binding(
                get: { inviteCode != nil },
                set: { if !$0 { inviteCode = nil } }
            )
        ) {
            Button("Copy link") {
                if let code = inviteCode {
                    copyToClipboard("https://fluxer.gg/\(code)")
                }
                inviteCode = nil
            }
            Button("Done", role: .cancel) { inviteCode = nil }
        } message: {
            Text(inviteCode.map { "fluxer.gg/\($0)" } ?? "")
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    @ViewBuilder
    private func row(for channel: Channel) -> some View {
        if channel.type == .guildVoice {
            VoiceChannelRow(channel: channel)
        } else {
            textRow(for: channel)
        }
    }

    @ViewBuilder
    private func textRow(for channel: Channel) -> some View {
        let label = HStack {
            Label(channel.name ?? "channel", systemImage: "number")
                .fontWeight(session.isUnread(channel) ? .bold : .regular)
            if session.isUnread(channel) {
                Spacer()
                MainView.UnreadDot()
            }
        }
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
            .contextMenu { inviteMenu(channel) }
        } else {
            NavigationLink(value: channel) {
                label
            }
            .contextMenu { inviteMenu(channel) }
        }
    }

    @ViewBuilder
    private func inviteMenu(_ channel: Channel) -> some View {
        if session.permissions(in: channel).contains(.createInstantInvite) {
            Button("Create invite", systemImage: "person.crop.circle.badge.plus") {
                Task {
                    inviteCode = await session.createInvite(in: channel)
                }
            }
        }
    }
}
