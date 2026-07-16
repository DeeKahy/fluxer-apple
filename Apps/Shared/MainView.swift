import SwiftUI
import FluxerKit

/// Signed-in shell. Wide layouts (Mac, iPad) get a three column split view
/// driven by selection state. Compact layouts (iPhone) get a navigation
/// stack that drills down: sidebar, then channels, then messages.
struct MainView: View {
    @Environment(AppSession.self) private var session
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var selectedGuild: Guild?
    @State private var selectedChannel: Channel?

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactLayout
        } else {
            splitLayout
        }
        #else
        splitLayout
        #endif
    }

    // MARK: Compact (iPhone)

    private var compactLayout: some View {
        NavigationStack {
            List {
                connectionRow
                Section("Direct messages") {
                    if session.privateChannels.isEmpty {
                        Text("No conversations")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.privateChannels) { channel in
                        NavigationLink(value: channel) {
                            dmRow(channel)
                        }
                    }
                }
                Section("Guilds") {
                    if session.guilds.isEmpty {
                        Text("No guilds yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.guilds) { guild in
                        NavigationLink(value: guild) {
                            guildRow(guild)
                        }
                    }
                }
            }
            .navigationTitle("Fluxer")
            .toolbar { accountMenu }
            .navigationDestination(for: Guild.self) { guild in
                ChannelListView(guild: guild)
            }
            .navigationDestination(for: Channel.self) { channel in
                MessageView(channel: channel)
            }
        }
    }

    // MARK: Split (Mac, iPad)

    private var splitLayout: some View {
        NavigationSplitView {
            List {
                connectionRow
                Section("Direct messages") {
                    if session.privateChannels.isEmpty {
                        Text("No conversations")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.privateChannels) { channel in
                        Button {
                            selectedGuild = nil
                            selectedChannel = channel
                        } label: {
                            dmRow(channel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Guilds") {
                    if session.guilds.isEmpty {
                        Text("No guilds yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.guilds) { guild in
                        Button {
                            selectedChannel = nil
                            selectedGuild = guild
                        } label: {
                            guildRow(guild)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Fluxer")
            .toolbar { accountMenu }
        } content: {
            if let guild = selectedGuild {
                ChannelListView(guild: guild, selectedChannel: $selectedChannel)
            } else {
                ContentUnavailableView(
                    "Pick a guild",
                    systemImage: "rectangle.3.group",
                    description: Text("Choose a guild or a conversation from the sidebar.")
                )
            }
        } detail: {
            if let channel = selectedChannel {
                MessageView(channel: channel)
            } else {
                ContentUnavailableView(
                    "No channel selected",
                    systemImage: "number",
                    description: Text("Pick a channel to start reading.")
                )
            }
        }
    }

    // MARK: Shared bits

    @ViewBuilder
    private var connectionRow: some View {
        if !session.gatewayConnected {
            Label("Connecting", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var accountMenu: some View {
        Menu {
            if let user = session.currentUser {
                Text(user.displayName)
            }
            Button("Log out", role: .destructive) {
                Task { await session.logout() }
            }
        } label: {
            Image(systemName: "person.circle")
        }
    }

    private func dmRow(_ channel: Channel) -> some View {
        HStack(spacing: 10) {
            if channel.type == .groupDM {
                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            } else {
                let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
                    ?? channel.recipients?.first
                AvatarView(user: other, diameter: 28)
            }
            Text(dmTitle(channel))
                .fontWeight(session.isUnread(channel) ? .bold : .regular)
            if session.isUnread(channel) {
                Spacer()
                UnreadDot()
            }
        }
    }

    private func guildRow(_ guild: Guild) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: guild.iconURL(size: 56)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.tint.opacity(0.25))
                    .overlay {
                        Text(String(guild.name.prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(guild.name)
                .fontWeight(session.hasUnread(guild) ? .bold : .regular)
            if session.hasUnread(guild) {
                Spacer()
                UnreadDot()
            }
        }
    }

    struct UnreadDot: View {
        var body: some View {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
        }
    }

    private func dmTitle(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty {
            return name
        }
        let recipients = channel.recipients ?? []
        let others = recipients.filter { $0.id != session.currentUser?.id }
        if others.isEmpty {
            return recipients.first?.displayName ?? "Conversation"
        }
        return others.map(\.displayName).joined(separator: ", ")
    }
}
