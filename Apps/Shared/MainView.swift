import SwiftUI
import FluxerKit

/// Signed-in shell: guilds and DMs in the sidebar, channels in the middle,
/// messages in the detail pane. Collapses to stacked navigation on iPhone.
struct MainView: View {
    @Environment(AppSession.self) private var session

    @State private var selectedGuild: Guild?
    @State private var selectedChannel: Channel?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Fluxer")
                .toolbar {
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

    private var sidebar: some View {
        List {
            if !session.gatewayConnected {
                Label("Connecting", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
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
                        Label(dmTitle(channel), systemImage: channel.type == .groupDM ? "person.2" : "person")
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
                        Label(guild.name, systemImage: "rectangle.3.group")
                    }
                    .buttonStyle(.plain)
                }
            }
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
