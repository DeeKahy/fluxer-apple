import SwiftUI
import FluxerKit

/// iPhone shell in the redesigned look: five tabs over an ink background
/// with a blurred custom tab bar, guilds presented as workspaces.
struct TabShell: View {
    @Environment(AppSession.self) private var session

    enum Tab: String, CaseIterable {
        case home, dms, activity, search, you
    }

    @State private var tab: Tab = .home
    @State private var path = NavigationPath()
    @State private var showWorkspaces = false
    @AppStorage("currentWorkspace") private var currentWorkspaceId = ""

    private var currentGuild: Guild? {
        session.guilds.first { $0.id.stringValue == currentWorkspaceId } ?? session.guilds.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.bg.ignoresSafeArea()
                switch tab {
                case .home:
                    HomeTab(guild: currentGuild, openWorkspaces: { showWorkspaces = true }) { channel in
                        path.append(channel)
                    }
                case .dms:
                    DMsTab { channel in
                        path.append(channel)
                    }
                case .activity:
                    ActivityTab()
                case .search:
                    SearchTab { channel in
                        path.append(channel)
                    }
                case .you:
                    YouTab()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    VoiceBar()
                    tabBar
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                IncomingCallBanner()
            }
            .navigationDestination(for: Channel.self) { channel in
                MessageView(channel: channel)
                    .background(Theme.bg)
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $showWorkspaces) {
            WorkspaceSwitcherView(currentId: $currentWorkspaceId)
        }
        .onChange(of: session.channelJump) { _, jump in
            guard let jump else { return }
            session.channelJump = nil
            path.append(jump)
        }
    }

    // MARK: Tab bar

    private var unreadDMCount: Int {
        session.privateChannels.filter { session.isUnread($0) }.count
    }

    private var mentionTotal: Int {
        session.mentionCounts.values.reduce(0, +)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(.home, icon: "house", label: "Home", badge: 0)
            tabItem(.dms, icon: "bubble.left", label: "DMs", badge: unreadDMCount)
            tabItem(.activity, icon: "bell", label: "Activity", badge: mentionTotal)
            tabItem(.search, icon: "magnifyingglass", label: "Search", badge: 0)
            tabItem(.you, icon: "person", label: "You", badge: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Theme.hairline.frame(height: 1)
        }
    }

    private func tabItem(_ target: Tab, icon: String, label: String, badge: Int) -> some View {
        Button {
            tab = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab == target ? icon + ".fill" : icon)
                    .font(.system(size: 21, weight: .regular))
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            CountBadge(count: badge)
                                .offset(x: 12, y: -6)
                        }
                    }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tab == target ? Theme.text : Theme.muted)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SquishButtonStyle())
    }
}

// MARK: - Home

struct HomeTab: View {
    @Environment(AppSession.self) private var session

    let guild: Guild?
    let openWorkspaces: () -> Void
    let openChannel: (Channel) -> Void

    @State private var showMembers = false
    @State private var showMentions = false
    @State private var showSaved = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    quickRows
                    if let guild {
                        channelSections(guild)
                    } else {
                        Text("Join a guild to get started")
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showMembers) {
            if let guild {
                MemberListView(guildId: guild.id)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            if let guild {
                Button(action: openWorkspaces) {
                    HStack(spacing: 11) {
                        GuildTile(guild: guild)
                        Text(guild.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .buttonStyle(SquishButtonStyle())
            } else {
                Text("Fluxer")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            CircleIconButton(systemImage: "person.2") {
                showMembers = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var quickRows: some View {
        VStack(spacing: 0) {
            quickRow(icon: "at", label: "Mentions & reactions", badge: session.mentionCounts.values.reduce(0, +)) {
                showMentions = true
            }
            quickRow(icon: "bookmark", label: "Saved messages", badge: 0) {
                showSaved = true
            }
        }
        .sheet(isPresented: $showMentions) {
            NavigationStack {
                MessageFeedView(feed: .mentions)
                    .background(Theme.bg)
                    .toolbar { Button("Done") { showMentions = false } }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSaved) {
            NavigationStack {
                MessageFeedView(feed: .saved)
                    .background(Theme.bg)
                    .toolbar { Button("Done") { showSaved = false } }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func quickRow(icon: String, label: String, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.icon)
                    .frame(width: 26)
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.rowText)
                Spacer()
                if badge > 0 {
                    CountBadge(count: badge)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
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

    private func sectionView(title: String, channels: [Channel]) -> some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: title)
                Spacer()
            }
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
        return Button {
            openChannel(channel)
        } label: {
            HStack(spacing: 10) {
                Text("#")
                    .font(.system(size: 18))
                    .foregroundStyle(unread ? Theme.icon : Theme.faint)
                    .frame(width: 22)
                Text(channel.name ?? "channel")
                    .font(.system(size: 16, weight: unread ? .bold : .regular))
                    .foregroundStyle(unread ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                Spacer()
                if mentions > 0 {
                    CountBadge(count: mentions)
                } else if unread {
                    Circle().fill(Theme.icon).frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableRowStyle())
        .contextMenu {
            if session.permissions(in: channel).contains(.createInstantInvite) {
                Button("Create invite", systemImage: "person.crop.circle.badge.plus") {
                    Task {
                        if let code = await session.createInvite(in: channel) {
                            copyInvite(code)
                        }
                    }
                }
            }
        }
    }

    private func copyInvite(_ code: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://fluxer.gg/\(code)", forType: .string)
        #else
        UIPasteboard.general.string = "https://fluxer.gg/\(code)"
        #endif
    }
}

// MARK: - DMs

struct DMsTab: View {
    @Environment(AppSession.self) private var session

    let openChannel: (Channel) -> Void

    @State private var showFriends = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Direct Messages")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Spacer()
                CircleIconButton(systemImage: "square.and.pencil") {
                    showFriends = true
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(session.privateChannels) { channel in
                        dmRow(channel)
                    }
                    if session.privateChannels.isEmpty {
                        Text("No conversations yet")
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showFriends) {
            NavigationStack {
                FriendsView()
                    .toolbar {
                        Button("Done") { showFriends = false }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func dmRow(_ channel: Channel) -> some View {
        let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
            ?? channel.recipients?.first
        let unread = session.isUnread(channel)
        let last = session.messages(in: channel.id).last
        return Button {
            openChannel(channel)
        } label: {
            HStack(spacing: 12) {
                if channel.type == .groupDM {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.bubble)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "person.2.fill")
                                .foregroundStyle(Theme.icon)
                        }
                } else {
                    AvatarView(user: other, diameter: 48)
                        .overlay(alignment: .bottomTrailing) {
                            PresenceDot(status: session.presenceStatus(for: other?.id))
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(dmTitle(channel))
                            .font(.system(size: 16, weight: unread ? .bold : .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer()
                        if let timestamp = last?.timestamp {
                            Text(Self.shortTime(timestamp))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    HStack {
                        Text(preview(last))
                            .font(.system(size: 14))
                            .foregroundStyle(unread ? Theme.soft : Theme.muted)
                            .lineLimit(1)
                        Spacer()
                        if unread {
                            CountBadge(count: 1, color: Theme.accent)
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableRowStyle())
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

    private func preview(_ message: Message?) -> String {
        guard let message else { return "Say hi" }
        if let content = message.content, !content.isEmpty {
            return content
        }
        return "Sent an attachment"
    }

    static func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Activity

struct ActivityTab: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 4)
            MessageFeedView(feed: .mentions)
                .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Search

struct SearchTab: View {
    @Environment(AppSession.self) private var session

    let openChannel: (Channel) -> Void

    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                TextField("Channels, people, guilds", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 11))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !query.isEmpty {
                        results
                    } else {
                        Text("Search channels, conversations, and friends by name.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .padding(20)
                    }
                }
                .padding(.horizontal, 8)
            }
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

        if !channels.isEmpty {
            SectionLabel(text: "Channels").padding(12)
            ForEach(channels, id: \.1.id) { pair in
                Button {
                    openChannel(pair.1)
                } label: {
                    HStack(spacing: 10) {
                        Text("#").foregroundStyle(Theme.faint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pair.1.name ?? "channel")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.rowText)
                            Text(pair.0.name)
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
        }
        if !dms.isEmpty {
            SectionLabel(text: "Conversations").padding(12)
            ForEach(dms) { channel in
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
        }
        if channels.isEmpty && dms.isEmpty {
            Text("Nothing matches \"\(query)\"")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .padding(20)
        }
    }
}

// MARK: - You

struct YouTab: View {
    @Environment(AppSession.self) private var session

    @State private var showSessions = false

    private let statuses: [(String, String, Color)] = [
        ("online", "Active", Theme.green),
        ("idle", "Away", Color(hex: 0xFAA61A)),
        ("dnd", "Do not disturb", Theme.red),
        ("invisible", "Invisible", Theme.faint),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("You")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                HStack(spacing: 14) {
                    AvatarView(user: session.currentUser, diameter: 66)
                        .overlay(alignment: .bottomTrailing) {
                            PresenceDot(status: session.myStatus == "invisible" ? nil : session.myStatus)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.currentUser?.displayName ?? "")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(Theme.text)
                        Text(session.currentUser?.username ?? "")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                SectionLabel(text: "Set yourself as")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(statuses.enumerated()), id: \.offset) { index, status in
                        Button {
                            Task { await session.setStatus(status.0) }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(status.2)
                                    .frame(width: 12, height: 12)
                                    .shadow(color: status.2.opacity(0.35), radius: 4)
                                Text(status.1)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                if session.myStatus == status.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.vertical, 13)
                            .padding(.horizontal, 15)
                        }
                        .buttonStyle(.plain)
                        if index < statuses.count - 1 {
                            Theme.hairline.frame(height: 1).padding(.leading, 39)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.bottom, 22)

                VStack(spacing: 0) {
                    settingsRow(icon: "laptopcomputer.and.iphone", tint: Theme.accent, label: "Sessions") {
                        showSessions = true
                    }
                    Theme.hairline.frame(height: 1).padding(.leading, 55)
                    settingsRow(icon: "server.rack", tint: Color(hex: 0x8B5CF6),
                                label: "Instance",
                                detail: session.instanceConfig.apiBase.host() ?? "") {}
                    Theme.hairline.frame(height: 1).padding(.leading, 55)
                    settingsRow(icon: "rectangle.portrait.and.arrow.right", tint: Theme.red, label: "Log out") {
                        Task { await session.logout() }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)

                Text("Fluxer for iOS and macOS")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            }
        }
        .sheet(isPresented: $showSessions) {
            SessionsView()
                .preferredColorScheme(.dark)
        }
    }

    private func settingsRow(
        icon: String,
        tint: Color,
        label: String,
        detail: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 15)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workspace switcher

struct WorkspaceSwitcherView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @Binding var currentId: String

    @State private var joinCode = ""
    @State private var showJoinPrompt = false
    @State private var newGuildName = ""
    @State private var showCreatePrompt = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Workspaces")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(session.guilds) { guild in
                            tile(guild)
                        }
                        addTile
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 40)
                }
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
    }

    private func tile(_ guild: Guild) -> some View {
        let unread = session.hasUnread(guild)
        return Button {
            currentId = guild.id.stringValue
            dismiss()
        } label: {
            VStack(spacing: 9) {
                GuildTile(guild: guild, size: 96, radius: 22)
                    .overlay(alignment: .topTrailing) {
                        if unread {
                            CountBadge(count: 1)
                                .offset(x: 6, y: -6)
                        }
                    }
                    .overlay {
                        if currentId == guild.id.stringValue {
                            RoundedRectangle(cornerRadius: 22)
                                .strokeBorder(Theme.accent, lineWidth: 2.5)
                        }
                    }
                Text(guild.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(currentId == guild.id.stringValue ? Theme.text : Theme.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(SquishButtonStyle())
        .contextMenu {
            if guild.ownerId != session.currentUser?.id {
                Button("Leave guild", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await session.leaveGuild(guild) }
                }
            }
        }
    }

    private var addTile: some View {
        Menu {
            Button("Join with invite", systemImage: "arrow.right.circle") {
                showJoinPrompt = true
            }
            Button("Create a guild", systemImage: "plus.circle") {
                showCreatePrompt = true
            }
        } label: {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                Text("Add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
