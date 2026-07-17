import SwiftUI
import FluxerKit

/// Mac and iPad shell in the ink design: a single rich sidebar with the
/// workspace header, quick rows, channels, and DMs, next to the chat pane.
struct DesktopShell: View {
    @Environment(AppSession.self) private var session

    @AppStorage("currentWorkspace") private var currentWorkspaceId = ""
    @State private var selectedChannel: Channel?
    @State private var showWorkspaces = false
    @State private var showFriends = false
    @State private var showMentions = false
    @State private var showSaved = false
    @State private var showSessions = false
    @State private var showMembers = false

    private var currentGuild: Guild? {
        session.guilds.first { $0.id.stringValue == currentWorkspaceId } ?? session.guilds.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 285)
        } detail: {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if let channel = selectedChannel {
                    MessageView(channel: channel)
                        .id(channel.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.faint)
                        Text("Pick a conversation")
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .top, spacing: 0) { IncomingCallBanner() }
        .safeAreaInset(edge: .bottom, spacing: 0) { VoiceBar() }
        .sheet(isPresented: $showWorkspaces) {
            WorkspaceSwitcherView(currentId: $currentWorkspaceId)
                .frame(minWidth: 540, minHeight: 480)
        }
        .sheet(isPresented: $showFriends) {
            NavigationStack {
                FriendsView().toolbar { Button("Done") { showFriends = false } }
            }
            .frame(minWidth: 420, minHeight: 500)
        }
        .sheet(isPresented: $showMentions) {
            NavigationStack {
                MessageFeedView(feed: .mentions).toolbar { Button("Done") { showMentions = false } }
            }
            .frame(minWidth: 440, minHeight: 480)
        }
        .sheet(isPresented: $showSaved) {
            NavigationStack {
                MessageFeedView(feed: .saved).toolbar { Button("Done") { showSaved = false } }
            }
            .frame(minWidth: 440, minHeight: 480)
        }
        .sheet(isPresented: $showSessions) {
            SessionsView()
        }
        .sheet(isPresented: $showMembers) {
            if let guild = currentGuild {
                MemberListView(guildId: guild.id)
            }
        }
        .onChange(of: session.channelJump) { _, jump in
            guard let jump else { return }
            session.channelJump = nil
            if let guildId = jump.guildId {
                currentWorkspaceId = guildId.stringValue
            }
            selectedChannel = jump
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                quickRows
                if let guild = currentGuild {
                    channelSections(guild)
                }
                HStack {
                    SectionLabel(text: "Direct messages")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 4)
                ForEach(session.privateChannels) { channel in
                    dmRow(channel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)
        }
        .background(Theme.bg)
        .toolbar {
            accountMenu
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let guild = currentGuild {
                Button {
                    showWorkspaces = true
                } label: {
                    HStack(spacing: 10) {
                        GuildTile(guild: guild, size: 30, radius: 9)
                        Text(guild.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .buttonStyle(SquishButtonStyle())
            } else {
                Text("Fluxer")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            CircleIconButton(systemImage: "person.2", size: 28) {
                showMembers = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
                            Label(status.capitalized, systemImage: "checkmark")
                        } else {
                            Text(status.capitalized)
                        }
                    }
                }
            }
            Button("Sessions") { showSessions = true }
            Divider()
            Button("Log out", role: .destructive) {
                Task { await session.logout() }
            }
        } label: {
            AvatarView(user: session.currentUser, diameter: 22)
        }
    }

    private var quickRows: some View {
        VStack(spacing: 0) {
            quickRow(icon: "person.2", label: "Friends") { showFriends = true }
            quickRow(icon: "at", label: "Mentions & reactions") { showMentions = true }
            quickRow(icon: "bookmark", label: "Saved messages") { showSaved = true }
        }
    }

    private func quickRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.icon)
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.rowText)
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableRowStyle())
    }

    @ViewBuilder
    private func channelSections(_ guild: Guild) -> some View {
        let all = (guild.channels ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
        let categories = all.filter { $0.type == .guildCategory }
        let leaves = all.filter { $0.type == .guildText || $0.type == .guildVoice }
        let uncategorized = leaves.filter { channel in
            channel.parentId == nil || !categories.contains { $0.id == channel.parentId }
        }
        Group {
            if !uncategorized.isEmpty {
                sectionView(title: "Channels", channels: uncategorized)
            }
            ForEach(categories) { category in
                let children = leaves.filter { $0.parentId == category.id }
                if !children.isEmpty {
                    sectionView(title: category.name ?? "Channels", channels: children)
                }
            }
        }
    }

    private func sectionView(title: String, channels: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ForEach(channels) { channel in
                if channel.type == .guildVoice {
                    VoiceChannelRow(channel: channel)
                } else {
                    channelRow(channel)
                }
            }
        }
    }

    private func channelRow(_ channel: Channel) -> some View {
        let unread = session.isUnread(channel)
        let mentions = session.mentionCounts[channel.id] ?? 0
        let selected = selectedChannel?.id == channel.id
        return RowTap(isSelected: selected) {
            selectedChannel = channel
            session.recordVisit(channel)
        } label: {
            HStack(spacing: 8) {
                Text("#")
                    .font(.system(size: 15))
                    .foregroundStyle(unread || selected ? Theme.icon : Theme.faint)
                    .frame(width: 18)
                Text(channel.name ?? "channel")
                    .font(.system(size: 14, weight: unread ? .bold : .regular))
                    .foregroundStyle(unread || selected ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                Spacer()
                if mentions > 0 {
                    CountBadge(count: mentions)
                } else if unread {
                    Circle().fill(Theme.icon).frame(width: 7, height: 7)
                }
            }
        }
    }

    private func dmRow(_ channel: Channel) -> some View {
        let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
            ?? channel.recipients?.first
        let unread = session.isUnread(channel)
        let selected = selectedChannel?.id == channel.id
        return RowTap(isSelected: selected) {
            selectedChannel = channel
        } label: {
            HStack(spacing: 9) {
                AvatarView(user: other, diameter: 26)
                    .overlay(alignment: .bottomTrailing) {
                        PresenceDot(status: session.presenceStatus(for: other?.id))
                    }
                Text(dmTitle(channel))
                    .font(.system(size: 14, weight: unread ? .bold : .regular))
                    .foregroundStyle(unread || selected ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                Spacer()
                if unread {
                    CountBadge(count: 1, color: Theme.accent)
                }
            }
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

    private func dmTitle(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }
}
