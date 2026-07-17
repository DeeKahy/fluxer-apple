import SwiftUI
import FluxerKit

/// Desktop shell in the comp's three column anatomy: a dark server rail
/// of guild tiles, a channel sidebar, and the chat column.
struct DesktopShell: View {
    @Environment(AppSession.self) private var session

    @AppStorage("currentWorkspace") private var currentWorkspaceId = ""
    @State private var selectedChannel: Channel?
    @State private var dmMode = false
    @State private var showFriends = false
    @State private var showMentions = false
    @State private var showSaved = false
    @State private var showSessions = false
    @State private var showMembers = false
    @State private var showJoinPrompt = false
    @State private var joinCode = ""
    @State private var showCreatePrompt = false
    @State private var newGuildName = ""

    private var currentGuild: Guild? {
        session.guilds.first { $0.id.stringValue == currentWorkspaceId } ?? session.guilds.first
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            sidebar
                .frame(width: 256)
                .background(Theme.sidebarBg)
                .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
            detail
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .top, spacing: 0) { IncomingCallBanner() }
        .safeAreaInset(edge: .bottom, spacing: 0) { VoiceBar() }
        .sheet(isPresented: $showFriends) {
            NavigationStack { FriendsView().toolbar { Button("Done") { showFriends = false } } }
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
        .sheet(isPresented: $showSessions) { SessionsView() }
        .sheet(isPresented: $showMembers) {
            if let guild = currentGuild {
                MemberListView(guildId: guild.id)
            }
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
        .onChange(of: session.channelJump) { _, jump in
            guard let jump else { return }
            session.channelJump = nil
            if let guildId = jump.guildId {
                currentWorkspaceId = guildId.stringValue
                dmMode = false
            } else {
                dmMode = true
            }
            selectedChannel = jump
        }
    }

    // MARK: Server rail

    private var rail: some View {
        VStack(spacing: 10) {
            railButton(
                selected: dmMode,
                badge: session.privateChannels.filter { session.isUnread($0) }.count,
                action: { dmMode = true }
            ) {
                RoundedRectangle(cornerRadius: dmMode ? 16 : 23)
                    .fill(dmMode ? Theme.accent : Theme.surface)
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(dmMode ? .white : Theme.icon)
                    }
            }
            Theme.hairline.frame(width: 30, height: 1)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(session.guilds) { guild in
                        let selected = !dmMode && currentGuild?.id == guild.id
                        railButton(
                            selected: selected,
                            badge: guildMentionCount(guild),
                            action: {
                                currentWorkspaceId = guild.id.stringValue
                                dmMode = false
                                if selectedChannel?.guildId != guild.id {
                                    selectedChannel = session.defaultChannel(for: guild)
                                }
                            }
                        ) {
                            GuildTile(guild: guild, size: 46, radius: selected ? 16 : 23)
                        }
                        .contextMenu {
                            if guild.ownerId != session.currentUser?.id {
                                Button("Leave guild", role: .destructive) {
                                    Task { await session.leaveGuild(guild) }
                                }
                            }
                        }
                    }
                    Menu {
                        Button("Join with invite", systemImage: "arrow.right.circle") { showJoinPrompt = true }
                        Button("Create a guild", systemImage: "plus.circle") { showCreatePrompt = true }
                    } label: {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Theme.surface)
                            .frame(width: 46, height: 46)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.green)
                            }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 46, height: 46)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if let user = session.currentUser { Text(user.displayName) }
                Menu("Status") {
                    ForEach(["online", "idle", "dnd", "invisible"], id: \.self) { status in
                        Button(status.capitalized) { Task { await session.setStatus(status) } }
                    }
                }
                Button("Sessions") { showSessions = true }
                Divider()
                Button("Log out", role: .destructive) { Task { await session.logout() } }
            } label: {
                AvatarView(user: session.currentUser, diameter: 34)
                    .overlay(alignment: .bottomTrailing) {
                        PresenceDot(status: session.myStatus == "invisible" ? nil : session.myStatus)
                    }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40, height: 40)
        }
        .padding(.vertical, 14)
        .frame(width: 74)
        .background(Theme.railBg)
    }

    private func guildMentionCount(_ guild: Guild) -> Int {
        (guild.channels ?? []).reduce(0) { total, channel in
            total + (session.mentionCounts[channel.id] ?? 0)
        }
    }

    private func railButton<C: View>(
        selected: Bool,
        badge: Int,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> C
    ) -> some View {
        Button(action: action) {
            content()
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { CountBadge(count: badge).offset(x: 4, y: -4) }
                }
        }
        .buttonStyle(SquishButtonStyle())
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 4, height: 36)
                    .offset(x: -14)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(dmMode ? "Direct Messages" : currentGuild?.name ?? "Fluxer")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                if !dmMode {
                    CircleIconButton(systemImage: "person.2", size: 26) { showMembers = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    quickRow(icon: "person.2", label: "Friends") { showFriends = true }
                    quickRow(icon: "at", label: "Mentions", badge: session.mentionCounts.values.reduce(0, +)) {
                        showMentions = true
                    }
                    quickRow(icon: "bookmark", label: "Saved messages") { showSaved = true }

                    if dmMode {
                        sectionHeader("Direct messages")
                        ForEach(session.privateChannels) { channel in
                            dmRow(channel)
                        }
                    } else if let guild = currentGuild {
                        channelSections(guild)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.sectionMuted)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 3)
    }

    private func quickRow(icon: String, label: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(label).font(.system(size: 14, weight: .medium))
                Spacer()
                if badge > 0 { CountBadge(count: badge) }
            }
            .foregroundStyle(Theme.icon)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
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
                sectionHeader("Channels")
                ForEach(uncategorized) { channelOrVoiceRow($0) }
            }
            ForEach(categories) { category in
                let children = leaves.filter { $0.parentId == category.id }
                if !children.isEmpty {
                    sectionHeader(category.name ?? "Channels")
                    ForEach(children) { channelOrVoiceRow($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func channelOrVoiceRow(_ channel: Channel) -> some View {
        if channel.type == .guildVoice {
            VoiceChannelRow(channel: channel)
        } else {
            let unread = session.isUnread(channel)
            let mentions = session.mentionCounts[channel.id] ?? 0
            let selected = selectedChannel?.id == channel.id
            RowTap(isSelected: selected) {
                selectedChannel = channel
                session.recordVisit(channel)
            } label: {
                HStack(spacing: 8) {
                    Text("#")
                        .font(.system(size: 15))
                        .foregroundStyle(unread || selected ? Theme.icon : Theme.sectionMuted)
                        .frame(width: 16)
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
            .contextMenu {
                if session.permissions(in: channel).contains(.createInstantInvite) {
                    Button("Create invite", systemImage: "person.crop.circle.badge.plus") {
                        Task {
                            if let code = await session.createInvite(in: channel) {
                                copyText("https://fluxer.gg/\(code)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func copyText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
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
                AvatarView(user: other, diameter: 28)
                    .overlay(alignment: .bottomTrailing) {
                        PresenceDot(status: session.presenceStatus(for: other?.id))
                    }
                Text(dmTitle(channel))
                    .font(.system(size: 14, weight: unread ? .bold : .regular))
                    .foregroundStyle(unread || selected ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                Spacer()
                if unread { CountBadge(count: 1, color: Theme.accent) }
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

    // MARK: Detail

    private var detail: some View {
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
}
