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
    @State private var compactPath = NavigationPath()
    @State private var showFriends = false
    @State private var showSaved = false
    @State private var showMentions = false
    @State private var showSessions = false
    @State private var joinCode = ""
    @State private var showJoinPrompt = false
    @State private var newGuildName = ""
    @State private var showCreatePrompt = false
    @State private var guildToLeave: Guild?

    var body: some View {
        Group {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            IncomingCallBanner()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VoiceBar()
        }
        .onChange(of: session.channelJump) { _, jump in
            guard let jump else { return }
            session.channelJump = nil
            #if os(iOS)
            if horizontalSizeClass == .compact {
                compactPath.append(jump)
                return
            }
            #endif
            if let guildId = jump.guildId {
                selectedGuild = session.guilds.first { $0.id == guildId }
            } else {
                selectedGuild = nil
            }
            selectedChannel = jump
        }
    }

    // MARK: Compact (iPhone)

    private var compactLayout: some View {
        TabShell()
    }

    private var compactStack: some View {
        NavigationStack(path: $compactPath) {
            List {
                connectionRow
                NavigationLink(value: FriendsRoute()) {
                    Label("Friends", systemImage: "person.2.fill")
                }
                Section("Direct messages") {
                    if session.privateChannels.isEmpty {
                        Text("No conversations")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.privateChannels) { channel in
                        NavigationLink(value: channel) {
                            dmRow(channel)
                        }
                        .contextMenu {
                            Button(
                                session.isDMPinned(channel) ? "Unpin conversation" : "Pin conversation",
                                systemImage: session.isDMPinned(channel) ? "pin.slash" : "pin"
                            ) {
                                Task { await session.toggleDMPinned(channel) }
                            }
                        }
                    }
                }
                Section("Guilds") {
                    if session.guilds.isEmpty {
                        Text("No guilds yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.guilds) { guild in
                        RowTap {
                            // Land in the last visited channel (or the first
                            // one), with the channel list a back tap away.
                            compactPath.append(guild)
                            if let channel = session.defaultChannel(for: guild) {
                                compactPath.append(channel)
                            }
                        } label: {
                            HStack {
                                guildRow(guild)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .rowTapInsets()
                        .contextMenu {
                            if guild.ownerId != session.currentUser?.id {
                                Button("Leave guild", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    guildToLeave = guild
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fluxer")
            .toolbar {
                addMenu
                accountMenu
            }
            .navigationDestination(for: Guild.self) { guild in
                ChannelListView(guild: guild)
            }
            .navigationDestination(for: Channel.self) { channel in
                MessageView(channel: channel)
            }
            .navigationDestination(for: FriendsRoute.self) { _ in
                FriendsView()
            }
        }
    }

    struct FriendsRoute: Hashable {}

    // MARK: Split (Mac, iPad)

    private var splitLayout: some View {
        withOverlays(splitView)
    }

    private var splitView: some View {
        NavigationSplitView {
            List {
                connectionRow
                RowTap {
                    showFriends = true
                } label: {
                    Label("Friends", systemImage: "person.2.fill")
                }
                .rowTapInsets()
                .sheet(isPresented: $showFriends) {
                    NavigationStack {
                        FriendsView()
                            .toolbar {
                                Button("Done") { showFriends = false }
                            }
                    }
                    .frame(minWidth: 400, minHeight: 500)
                }
                Section("Direct messages") {
                    if session.privateChannels.isEmpty {
                        Text("No conversations")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.privateChannels) { channel in
                        RowTap(isSelected: selectedChannel?.id == channel.id && selectedGuild == nil) {
                            selectedGuild = nil
                            selectedChannel = channel
                        } label: {
                            dmRow(channel)
                        }
                        .rowTapInsets()
                        .contextMenu {
                            Button(
                                session.isDMPinned(channel) ? "Unpin conversation" : "Pin conversation",
                                systemImage: session.isDMPinned(channel) ? "pin.slash" : "pin"
                            ) {
                                Task { await session.toggleDMPinned(channel) }
                            }
                        }
                    }
                }
                Section("Guilds") {
                    if session.guilds.isEmpty {
                        Text("No guilds yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.guilds) { guild in
                        RowTap(isSelected: selectedGuild?.id == guild.id) {
                            selectedGuild = guild
                            selectedChannel = session.defaultChannel(for: guild)
                        } label: {
                            guildRow(guild)
                        }
                        .rowTapInsets()
                        .contextMenu {
                            if guild.ownerId != session.currentUser?.id {
                                Button("Leave guild", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    guildToLeave = guild
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fluxer")
            .toolbar {
                addMenu
                accountMenu
            }
        } content: {
            if let guild = selectedGuild {
                ChannelListView(guild: guild, selectedChannel: $selectedChannel)
            } else {
                List {
                    ForEach(session.privateChannels) { channel in
                        RowTap(isSelected: selectedChannel?.id == channel.id) {
                            selectedChannel = channel
                        } label: {
                            dmRow(channel)
                        }
                        .rowTapInsets()
                    }
                }
                .navigationTitle("Direct messages")
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
            Menu("Status") {
                ForEach(["online", "idle", "dnd", "invisible"], id: \.self) { status in
                    Button {
                        Task { await session.setStatus(status) }
                    } label: {
                        if session.myStatus == status {
                            Label(statusLabel(status), systemImage: "checkmark")
                        } else {
                            Text(statusLabel(status))
                        }
                    }
                }
            }
            Button("Saved messages", systemImage: "bookmark") {
                showSaved = true
            }
            Button("Recent mentions", systemImage: "at") {
                showMentions = true
            }
            Button("Sessions", systemImage: "laptopcomputer.and.iphone") {
                showSessions = true
            }
            Divider()
            Button("Log out", role: .destructive) {
                Task { await session.logout() }
            }
        } label: {
            Image(systemName: "person.circle")
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "online": return "Online"
        case "idle": return "Idle"
        case "dnd": return "Do not disturb"
        default: return "Invisible"
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Join a guild", systemImage: "arrow.right.circle") {
                showJoinPrompt = true
            }
            Button("Create a guild", systemImage: "plus.circle") {
                showCreatePrompt = true
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    /// Sheets and prompts shared by both layouts.
    private func withOverlays<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $showSaved) {
                NavigationStack {
                    MessageFeedView(feed: .saved)
                        .toolbar { Button("Done") { showSaved = false } }
                }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 460)
                #endif
            }
            .sheet(isPresented: $showMentions) {
                NavigationStack {
                    MessageFeedView(feed: .mentions)
                        .toolbar { Button("Done") { showMentions = false } }
                }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 460)
                #endif
            }
            .sheet(isPresented: $showSessions) {
                SessionsView()
            }
            .alert("Join a guild", isPresented: $showJoinPrompt) {
                TextField("Invite code or link", text: $joinCode)
                Button("Join") {
                    let code = joinCode
                    joinCode = ""
                    Task { _ = await session.joinGuild(code: code) }
                }
                Button("Cancel", role: .cancel) { joinCode = "" }
            }
            .alert("Create a guild", isPresented: $showCreatePrompt) {
                TextField("Guild name", text: $newGuildName)
                Button("Create") {
                    let name = newGuildName
                    newGuildName = ""
                    Task { _ = await session.createGuild(name: name) }
                }
                Button("Cancel", role: .cancel) { newGuildName = "" }
            }
            .alert(
                "Leave \(guildToLeave?.name ?? "guild")?",
                isPresented: Binding(
                    get: { guildToLeave != nil },
                    set: { if !$0 { guildToLeave = nil } }
                )
            ) {
                Button("Leave", role: .destructive) {
                    if let guild = guildToLeave {
                        Task { await session.leaveGuild(guild) }
                    }
                    guildToLeave = nil
                }
                Button("Cancel", role: .cancel) { guildToLeave = nil }
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
                    .overlay(alignment: .bottomTrailing) {
                        PresenceDot(status: session.presenceStatus(for: other?.id))
                    }
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
            RemoteImage(url: guild.iconURL(size: 56)) {
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
