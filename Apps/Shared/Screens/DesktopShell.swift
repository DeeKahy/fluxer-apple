import SwiftUI
import FluxerKit

/// Marks views living inside the desktop shell so shared screens can
/// swap in the desktop styling (hover tools, boxed composer).
private struct DesktopChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var desktopChrome: Bool {
        get { self[DesktopChromeKey.self] }
        set { self[DesktopChromeKey.self] = newValue }
    }
}

/// Desktop shell in the comp's anatomy: workspace rail, one sidebar with
/// channels + voice + DMs, the chat column, and slide-in right panels.
struct DesktopShell: View {
    @Environment(AppSession.self) private var session

    @AppStorage("currentWorkspace") private var currentWorkspaceId = ""
    @State private var selectedChannel: Channel?
    @State private var searchText = ""
    @State private var showMembers = false
    @State private var profileUser: User?
    @State private var showPins = false
    @State private var callMinimized = false
    @State private var callConnectedAt: Date?
    @State private var showJoinPrompt = false
    @State private var joinCode = ""
    @State private var showCreatePrompt = false
    @State private var newGuildName = ""

    private var currentGuild: Guild? {
        session.guilds.first { $0.id.stringValue == currentWorkspaceId } ?? session.guilds.first
    }

    private var callActive: Bool { session.voice.isActive }

    var body: some View {
        HStack(spacing: 0) {
            DesktopRail(
                currentGuildId: currentGuild?.id,
                onSelect: { guild in
                    currentWorkspaceId = guild.id.stringValue
                    if selectedChannel?.guildId != guild.id {
                        selectedChannel = session.defaultChannel(for: guild)
                    }
                },
                onJoin: { showJoinPrompt = true },
                onCreate: { showCreatePrompt = true }
            )
            DesktopSidebar(
                guild: currentGuild,
                selectedChannel: $selectedChannel,
                searchText: $searchText,
                onRestoreCall: { callMinimized = false },
                onOpenProfile: { profileUser = $0 }
            )
            .frame(width: 256)
            .background(Theme.sidebarBg)
            .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
            mainColumn
            if showMembers, let guild = currentGuild {
                DesktopMembersPanel(
                    guildId: guild.id,
                    onClose: { showMembers = false },
                    onOpenProfile: { profileUser = $0 }
                )
                .transition(.move(edge: .trailing))
            } else if let user = profileUser {
                DesktopProfilePanel(
                    user: user,
                    onClose: { profileUser = nil },
                    onOpenDM: { channel in
                        profileUser = nil
                        selectedChannel = channel
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.deskBg)
        .safeAreaInset(edge: .top, spacing: 0) { IncomingCallBanner() }
        .sheet(isPresented: $showPins) {
            if let channel = selectedChannel {
                PinsView(channel: channel)
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
            }
            selectedChannel = jump
            searchText = ""
        }
        .onChange(of: callActive) { _, active in
            callMinimized = false
            callConnectedAt = active ? Date() : nil
        }
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            DesktopConversationHeader(
                channel: selectedChannel,
                membersOpen: showMembers,
                onPins: { showPins = true },
                onToggleMembers: {
                    profileUser = nil
                    showMembers.toggle()
                }
            )
            ZStack {
                Group {
                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        DesktopSearchResults(
                            query: searchText,
                            guild: currentGuild,
                            onOpenChannel: { channel in
                                selectedChannel = channel
                                searchText = ""
                            },
                            onOpenProfile: { profileUser = $0 }
                        )
                    } else if let channel = selectedChannel {
                        MessageView(channel: channel)
                            .id(channel.id)
                            .environment(\.desktopChrome, true)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(Theme.faint)
                            Text("Pick a conversation")
                                .foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if callActive && !callMinimized {
                    DesktopCallView(
                        connectedAt: callConnectedAt,
                        onMinimize: { callMinimized = true }
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.deskBg)
        .overlay(alignment: .bottomTrailing) {
            if callActive && callMinimized {
                DesktopCallPill(
                    connectedAt: callConnectedAt,
                    onOpen: { callMinimized = false }
                )
                .padding([.trailing, .bottom], 20)
            }
        }
    }
}

// MARK: - Server rail

private struct DesktopRail: View {
    @Environment(AppSession.self) private var session

    let currentGuildId: Snowflake?
    let onSelect: (Guild) -> Void
    let onJoin: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(session.guilds) { guild in
                        RailButton(
                            selected: currentGuildId == guild.id,
                            badge: mentionCount(guild),
                            action: { onSelect(guild) }
                        ) { active in
                            GuildTile(guild: guild, size: 46, radius: active ? 16 : 23)
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
                        Button("Join with invite", systemImage: "arrow.right.circle", action: onJoin)
                        Button("Create a guild", systemImage: "plus.circle", action: onCreate)
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
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 74)
        .frame(maxHeight: .infinity)
        .background(Theme.railBg)
    }

    private func mentionCount(_ guild: Guild) -> Int {
        (guild.channels ?? []).reduce(0) { $0 + (session.mentionCounts[$1.id] ?? 0) }
    }
}

/// One rail tile: white selection bar on the left edge, squircle morph on
/// hover or selection, badge riding the bottom right corner.
private struct RailButton<Content: View>: View {
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    content(selected || hovered)
                        .overlay(alignment: .bottomTrailing) {
                            if badge > 0 {
                                CountBadge(count: badge)
                                    .background {
                                        Capsule().fill(Theme.railBg).padding(-3)
                                    }
                                    .offset(x: 5, y: 3)
                            }
                        }
                }
                .buttonStyle(SquishButtonStyle())
                .onHover { hovered = $0 }
                Spacer(minLength: 0)
            }
            UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                .fill(.white)
                .frame(width: 4, height: selected ? 40 : 0)
        }
        .frame(width: 74)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

// MARK: - Sidebar

private struct DesktopSidebar: View {
    @Environment(AppSession.self) private var session

    let guild: Guild?
    @Binding var selectedChannel: Channel?
    @Binding var searchText: String
    let onRestoreCall: () -> Void
    let onOpenProfile: (User) -> Void

    @State private var showFriends = false
    @State private var showMentions = false
    @State private var showSaved = false
    @State private var showSessions = false
    @State private var showGuildInvite = false

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    quickRow(icon: "at", label: "Mentions", badge: session.mentionCounts.values.reduce(0, +)) {
                        showMentions = true
                    }
                    quickRow(icon: "bookmark", label: "Saved messages") { showSaved = true }
                    quickRow(icon: "person.2", label: "Friends") { showFriends = true }
                    if let guild {
                        channelSections(guild)
                    }
                    dmSection
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
                .padding(.top, 2)
            }
            if session.voice.isActive {
                voiceConnectedBar
            }
            selfBar
        }
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
    }

    private var header: some View {
        Menu {
            if let guild {
                if let channel = session.defaultChannel(for: guild),
                   session.permissions(in: channel).contains(.createInstantInvite) {
                    Button("Invite people", systemImage: "person.crop.circle.badge.plus") {
                        Task {
                            if let code = await session.createInvite(in: channel) {
                                copyToClipboard("https://fluxer.gg/\(code)")
                            }
                        }
                    }
                }
                if guild.ownerId != session.currentUser?.id {
                    Button("Leave guild", role: .destructive) {
                        Task { await session.leaveGuild(guild) }
                    }
                }
            }
        } label: {
            HStack {
                Text(guild?.name ?? "Fluxer")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.sidebarField, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func quickRow(icon: String, label: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.sectionMuted)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 3)
    }

    // MARK: Channels

    @ViewBuilder
    private func channelSections(_ guild: Guild) -> some View {
        let all = (guild.channels ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
        let categories = all.filter { $0.type == .guildCategory }
        let text = all.filter { $0.type == .guildText }
        let voice = all.filter { $0.type == .guildVoice }
        let uncategorizedText = text.filter { channel in
            channel.parentId == nil || !categories.contains { $0.id == channel.parentId }
        }
        Group {
            if !uncategorizedText.isEmpty {
                sectionHeader("Channels")
                ForEach(uncategorizedText) { textChannelRow($0) }
            }
            ForEach(categories) { category in
                let children = text.filter { $0.parentId == category.id }
                if !children.isEmpty {
                    sectionHeader(category.name ?? "Channels")
                    ForEach(children) { textChannelRow($0) }
                }
            }
            if !voice.isEmpty {
                sectionHeader("Voice channels")
                ForEach(voice) { voiceChannelRow($0) }
            }
        }
    }

    private func textChannelRow(_ channel: Channel) -> some View {
        let unread = session.isUnread(channel)
        let mentions = session.mentionCounts[channel.id] ?? 0
        let selected = selectedChannel?.id == channel.id
        return Button {
            selectedChannel = channel
            searchText = ""
            session.recordVisit(channel)
        } label: {
            HStack(spacing: 8) {
                Text("#")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.text : (unread ? Theme.icon : Theme.sectionMuted))
                    .frame(width: 16)
                Text(channel.name ?? "channel")
                    .font(.system(size: 14, weight: selected || unread ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : (unread ? Theme.text : Color(hex: 0x9A9AA8)))
                    .lineLimit(1)
                Spacer()
                if mentions > 0 {
                    CountBadge(count: mentions)
                } else if unread {
                    Circle().fill(Theme.icon).frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                selected ? Theme.accent.opacity(0.22) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressableRowStyle())
        .contextMenu {
            if session.permissions(in: channel).contains(.createInstantInvite) {
                Button("Create invite", systemImage: "person.crop.circle.badge.plus") {
                    Task {
                        if let code = await session.createInvite(in: channel) {
                            copyToClipboard("https://fluxer.gg/\(code)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func voiceChannelRow(_ channel: Channel) -> some View {
        let joined = session.voice.connectedChannelId == channel.id
        let occupants = Array(session.voiceChannelUsers[channel.id] ?? []).sorted()
        Button {
            if joined {
                onRestoreCall()
            } else {
                Task { await session.joinVoice(channel) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(joined ? Theme.green : Theme.sectionMuted)
                    .frame(width: 16)
                Text(channel.name ?? "voice")
                    .font(.system(size: 14))
                    .foregroundStyle(joined ? Theme.text : Color(hex: 0x9A9AA8))
                    .lineLimit(1)
                Spacer()
                if joined {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .kerning(0.5)
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                joined ? Theme.green.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressableRowStyle())
        ForEach(occupants, id: \.self) { userId in
            let user = userId == session.currentUser?.id ? session.currentUser : session.knownUsers[userId]
            Button {
                if let user, user.id != session.currentUser?.id {
                    onOpenProfile(user)
                }
            } label: {
                HStack(spacing: 8) {
                    AvatarView(user: user, diameter: 22)
                        .overlay {
                            if session.voice.speakingUserIds.contains(userId) {
                                Circle().strokeBorder(Theme.green, lineWidth: 2)
                            }
                        }
                    Text(occupantName(user, userId: userId))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.icon)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.leading, 30)
                .padding(.trailing, 10)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(PressableRowStyle())
        }
    }

    private func occupantName(_ user: User?, userId: Snowflake) -> String {
        let name = user?.displayName ?? "Unknown"
        return userId == session.currentUser?.id ? "\(name) (you)" : name
    }

    // MARK: DMs

    @ViewBuilder
    private var dmSection: some View {
        if !session.privateChannels.isEmpty {
            sectionHeader("Direct messages")
            ForEach(session.privateChannels) { channel in
                dmRow(channel)
            }
        }
    }

    private func dmRow(_ channel: Channel) -> some View {
        let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
            ?? channel.recipients?.first
        let unread = session.isUnread(channel)
        let selected = selectedChannel?.id == channel.id
        return Button {
            selectedChannel = channel
            searchText = ""
        } label: {
            HStack(spacing: 9) {
                AvatarView(user: other, diameter: 22)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Theme.presenceColor(session.presenceStatus(for: other?.id)))
                            .frame(width: 9, height: 9)
                            .overlay { Circle().strokeBorder(Theme.sidebarBg, lineWidth: 2) }
                            .offset(x: 2, y: 2)
                    }
                Text(dmTitle(channel))
                    .font(.system(size: 14, weight: selected || unread ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : (unread ? Theme.text : Color(hex: 0x9A9AA8)))
                    .lineLimit(1)
                Spacer()
                if unread { CountBadge(count: 1, color: Theme.accent) }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                selected ? Theme.accent.opacity(0.22) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
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

    // MARK: Voice connected + self bar

    private var voiceConnectedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.green)
            Button(action: onRestoreCall) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice Connected")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.green)
                    Text(voiceChannelName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            Button {
                Task { await session.voice.toggleScreenShare() }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(session.voice.screenSharing ? Theme.accentSoft : Theme.icon)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
            #endif
            Button {
                Task { await session.voice.leave() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.red)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SquishButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.green.opacity(0.09))
        .overlay(alignment: .top) { Theme.green.opacity(0.22).frame(height: 1) }
    }

    private var voiceChannelName: String {
        guard let channelId = session.voice.connectedChannelId,
              let channel = session.findChannel(channelId)
        else { return "Voice" }
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }

    private var selfBar: some View {
        HStack(spacing: 9) {
            Menu {
                Button("Sessions") { showSessions = true }
                Divider()
                Button("Log out", role: .destructive) { Task { await session.logout() } }
            } label: {
                AvatarView(user: session.currentUser, diameter: 32)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Theme.presenceColor(session.myStatus == "invisible" ? nil : session.myStatus))
                            .frame(width: 10, height: 10)
                            .overlay { Circle().strokeBorder(Theme.selfBarBg, lineWidth: 2) }
                            .offset(x: 2, y: 2)
                    }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.currentUser?.displayName ?? "You")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(statusLabel(session.myStatus))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            ForEach(["online", "idle", "dnd", "invisible"], id: \.self) { status in
                Button {
                    Task { await session.setStatus(status) }
                } label: {
                    Circle()
                        .fill(Theme.presenceColor(status == "invisible" ? nil : status))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if session.myStatus == status {
                                Circle().strokeBorder(.white, lineWidth: 2)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(SquishButtonStyle())
                .help(statusLabel(status))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.selfBarBg)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "online": return "Active"
        case "idle": return "Away"
        case "dnd": return "Do not disturb"
        default: return "Invisible"
        }
    }
}

// MARK: - Conversation header

private struct DesktopConversationHeader: View {
    @Environment(AppSession.self) private var session

    let channel: Channel?
    let membersOpen: Bool
    let onPins: () -> Void
    let onToggleMembers: () -> Void

    private var isDM: Bool {
        channel?.type == .dm || channel?.type == .groupDM
    }

    private var dmUser: User? {
        (channel?.recipients ?? []).first { $0.id != session.currentUser?.id }
            ?? channel?.recipients?.first
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if let channel {
                    if isDM {
                        AvatarView(user: dmUser, diameter: 26)
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .fill(Theme.presenceColor(session.presenceStatus(for: dmUser?.id)))
                                    .frame(width: 9, height: 9)
                                    .overlay { Circle().strokeBorder(Theme.deskBg, lineWidth: 2) }
                                    .offset(x: 2, y: 2)
                            }
                    } else {
                        Text("#")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.muted)
                    }
                    Text(title(channel))
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let subtitle {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 2)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                if let channel, isDM {
                    headerButton("phone", help: "Start call") {
                        Task { await session.startCall(in: channel) }
                    }
                    .disabled(session.voice.connectedChannelId == channel.id)
                }
                if channel != nil {
                    headerButton("pin", help: "Pinned messages", action: onPins)
                }
                if let channel, channel.guildId != nil,
                   session.permissions(in: channel).contains(.viewChannelMembers) {
                    headerButton(
                        "person.2",
                        help: "Members",
                        tint: membersOpen ? Theme.accentSoft : Theme.icon,
                        action: onToggleMembers
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
    }

    private func title(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        let joined = others.map(\.displayName).joined(separator: ", ")
        return joined.isEmpty ? "Conversation" : joined
    }

    private var subtitle: String? {
        guard let channel else { return nil }
        if isDM {
            let status = session.presenceStatus(for: dmUser?.id)
            switch status {
            case "online": return "Active now"
            case "idle": return "Away"
            case "dnd": return "Do not disturb"
            default: return "Offline"
            }
        }
        if let topic = channel.topic, !topic.isEmpty { return topic }
        return nil
    }

    private func headerButton(
        _ icon: String,
        help: String,
        tint: Color = Theme.icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SquishButtonStyle())
        .help(help)
    }
}

// MARK: - Search results

private struct DesktopSearchResults: View {
    @Environment(AppSession.self) private var session

    let query: String
    let guild: Guild?
    let onOpenChannel: (Channel) -> Void
    let onOpenProfile: (User) -> Void

    private var normalized: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var matchedChannels: [Channel] {
        let channels = (guild?.channels ?? []).filter {
            $0.type == .guildText || $0.type == .guildVoice
        }
        return channels.filter { ($0.name ?? "").lowercased().contains(normalized) }
    }

    private var matchedDMs: [Channel] {
        session.privateChannels.filter { channel in
            let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
            let name = channel.name ?? others.map(\.displayName).joined(separator: ", ")
            return name.lowercased().contains(normalized)
        }
    }

    private var matchedPeople: [User] {
        var seen: Set<Snowflake> = []
        var result: [User] = []
        let candidates = session.knownUsers.values.sorted { $0.displayName < $1.displayName }
        for user in candidates {
            guard !seen.contains(user.id),
                  user.displayName.lowercased().contains(normalized)
                    || (user.username ?? "").lowercased().contains(normalized)
            else { continue }
            seen.insert(user.id)
            result.append(user)
            if result.count >= 8 { break }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                (Text("Results for ").foregroundStyle(Theme.secondary)
                    + Text("\"\(query)\"").bold().foregroundStyle(Theme.text))
                    .font(.system(size: 15))
                    .padding(.bottom, 18)

                if !matchedPeople.isEmpty {
                    resultHeader("People")
                    ForEach(matchedPeople) { user in
                        Button {
                            onOpenProfile(user)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(user: user, diameter: 38)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    if let username = user.username {
                                        Text(username)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer()
                            }
                            .padding(8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(PressableRowStyle())
                    }
                }

                if !matchedChannels.isEmpty {
                    resultHeader("Channels")
                    ForEach(matchedChannels) { channel in
                        channelResult(channel, glyph: channel.type == .guildVoice ? "speaker.wave.2" : nil)
                    }
                }

                if !matchedDMs.isEmpty {
                    resultHeader("Direct messages")
                    ForEach(matchedDMs) { channel in
                        channelResult(channel, glyph: "bubble.left")
                    }
                }

                if matchedPeople.isEmpty && matchedChannels.isEmpty && matchedDMs.isEmpty {
                    Text("No results found.")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.deskBg)
    }

    private func resultHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.sectionMuted)
            .padding(.top, 14)
            .padding(.bottom, 10)
    }

    private func channelResult(_ channel: Channel, glyph: String?) -> some View {
        Button {
            onOpenChannel(channel)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.deskTile)
                    .frame(width: 30, height: 30)
                    .overlay {
                        if let glyph {
                            Image(systemName: glyph)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accentSoft)
                        } else {
                            Text("#").foregroundStyle(Theme.accentSoft)
                        }
                    }
                Text(channelResultName(channel))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableRowStyle())
    }

    private func channelResultName(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }
}

// MARK: - Members panel

private struct DesktopMembersPanel: View {
    @Environment(AppSession.self) private var session

    let guildId: Snowflake
    let onClose: () -> Void
    let onOpenProfile: (User) -> Void

    private var guild: Guild? {
        session.guilds.first { $0.id == guildId }
    }

    private var members: [GuildMember] {
        session.guildMembers[guildId] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Members · \(members.count)")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Spacer()
                PanelCloseButton(action: onClose)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if session.guildMembers[guildId] == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                        Button {
                            if let user = member.user { onOpenProfile(user) }
                        } label: {
                            HStack(spacing: 11) {
                                AvatarView(user: member.user, diameter: 36)
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(Theme.presenceColor(session.presenceStatus(for: member.user?.id)))
                                            .frame(width: 11, height: 11)
                                            .overlay { Circle().strokeBorder(Theme.panelBg, lineWidth: 2) }
                                            .offset(x: 2, y: 2)
                                    }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    if let username = member.user?.username, username != member.displayName {
                                        Text(username)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.muted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(PressableRowStyle())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 300)
        .background(Theme.panelBg)
        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
        .task {
            if let guild {
                await session.loadMembers(for: guild)
            }
        }
    }
}

// MARK: - Profile panel

private struct DesktopProfilePanel: View {
    @Environment(AppSession.self) private var session

    let user: User
    let onClose: () -> Void
    let onOpenDM: (Channel) -> Void

    @State private var profile: APIClient.UserProfile?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(Theme.tileColor(for: user.id))
                        .frame(height: 110)
                    PanelCloseButton(dark: true, action: onClose)
                        .padding(12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    AvatarView(user: user, diameter: 72)
                        .overlay {
                            Circle().strokeBorder(Theme.panelBg, lineWidth: 5)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .fill(Theme.presenceColor(session.presenceStatus(for: user.id)))
                                .frame(width: 17, height: 17)
                                .overlay { Circle().strokeBorder(Theme.panelBg, lineWidth: 3) }
                        }
                        .offset(y: -36)
                        .padding(.bottom, -36)
                    Text(user.displayName)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .padding(.top, 10)
                    if let username = user.username {
                        Text("@\(username)")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.presenceColor(session.presenceStatus(for: user.id)))
                            .frame(width: 8, height: 8)
                        Text(presenceLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.soft)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                    .padding(.top, 10)
                    if user.id != session.currentUser?.id {
                        Button {
                            Task {
                                if let dm = await session.openDM(with: user.id) {
                                    onOpenDM(dm)
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.system(size: 13))
                                Text("Message")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(SquishButtonStyle())
                        .padding(.top, 16)
                    }
                    if let pronouns = profile?.pronouns, !pronouns.isEmpty {
                        panelLabel("Pronouns")
                        panelCard { Text(pronouns) }
                    }
                    if let bio = profile?.bio, !bio.isEmpty {
                        panelLabel("About")
                        panelCard { Text(bio) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 320)
        .background(Theme.panelBg)
        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
        .task(id: user.id) {
            profile = await session.profile(of: user.id)
        }
    }

    private var presenceLabel: String {
        switch session.presenceStatus(for: user.id) {
        case "online": return "Active now"
        case "idle": return "Away"
        case "dnd": return "Do not disturb"
        default: return "Offline"
        }
    }

    private func panelLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.sectionMuted)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func panelCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .font(.system(size: 14))
            .foregroundStyle(Theme.soft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Small x button used by the right panels.
struct PanelCloseButton: View {
    var dark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(dark ? .white : Theme.icon)
                .frame(width: 30, height: 30)
                .background(
                    dark ? AnyShapeStyle(.black.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SquishButtonStyle())
    }
}

func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
