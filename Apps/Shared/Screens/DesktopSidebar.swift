import SwiftUI
import FluxerKit

struct DesktopSidebar: View {
    @Environment(AppSession.self) private var session

    let guild: Guild?
    @Binding var selectedChannel: Channel?
    @Binding var searchText: String
    let onRestoreCall: () -> Void
    let onOpenProfile: (User) -> Void

    @State private var showFriends = false
    @State private var showMentions = false
    @State private var showSaved = false
    @State private var showGuildInvite = false

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    quickRow(icon: "at", label: "Mentions", badge: session.guildMentionTotal) {
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
                DesktopVoiceConnectedBar(onRestore: onRestoreCall)
            }
            DesktopSelfBar()
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
            HStack(spacing: 6) {
                Text(guild?.name ?? "CornFlux")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46)
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
        .buttonStyle(DeskRowStyle())
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
        .buttonStyle(DeskRowStyle())
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
        let selected = selectedChannel?.id == channel.id
        let unread = session.isUnread(channel)
        let mentions = session.mentionCounts[channel.id] ?? 0
        let occupants = Array(session.voiceChannelUsers[channel.id] ?? []).sorted()
        // Voice channels are text channels in Fluxer: clicking one opens
        // its chat, the phone button (or the header's) joins the call.
        Button {
            if joined {
                selectedChannel = channel
                onRestoreCall()
            } else {
                selectedChannel = channel
                searchText = ""
                session.recordVisit(channel)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(joined ? Theme.green : (selected ? Theme.text : Theme.sectionMuted))
                    .frame(width: 16)
                Text(channel.name ?? "voice")
                    .font(.system(size: 14, weight: selected || unread ? .semibold : .regular))
                    .foregroundStyle(joined || selected ? Theme.text : (unread ? Theme.text : Color(hex: 0x9A9AA8)))
                    .lineLimit(1)
                Spacer()
                if mentions > 0 {
                    CountBadge(count: mentions)
                }
                if joined {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .kerning(0.5)
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Button {
                        Task { await session.joinVoice(channel) }
                    } label: {
                        Image(systemName: "phone")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.sectionMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(SquishButtonStyle())
                    .help("Join voice")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                joined ? Theme.green.opacity(0.14) : (selected ? Theme.accent.opacity(0.22) : .clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(DeskRowStyle())
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
                    if session.isVoiceMuted(userId) {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.red)
                    }
                }
                .padding(.vertical, 3)
                .padding(.leading, 30)
                .padding(.trailing, 10)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(DeskRowStyle())
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
        .buttonStyle(DeskRowStyle())
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
