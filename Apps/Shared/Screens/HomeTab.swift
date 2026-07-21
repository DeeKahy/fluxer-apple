import SwiftUI
import FluxerKit

struct HomeTab: View {
    @Environment(AppSession.self) private var session

    let guild: Guild?
    let openWorkspaces: () -> Void
    let openChannel: (Channel) -> Void

    @State private var showMembers = false
    @State private var showMentions = false
    @State private var showSaved = false

    var body: some View {
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
        .background(Theme.bg)
        .navigationTitle(guild?.name ?? "Fluxer")
        .toolbarTitleMenu {
            ForEach(session.guilds) { g in
                Button {
                    openWorkspace(g)
                } label: {
                    Label(g.name, systemImage: g.id == guild?.id ? "checkmark" : "square.grid.2x2")
                }
            }
            Divider()
            Button("All workspaces", systemImage: "square.grid.2x2") {
                openWorkspaces()
            }
        }
        .toolbar {
            if guild != nil {
                Button {
                    showMembers = true
                } label: {
                    Image(systemName: "person.2")
                }
            }
        }
        .sheet(isPresented: $showMembers) {
            if let guild {
                MemberListView(guildId: guild.id)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private func openWorkspace(_ guild: Guild) {
        UserDefaults.standard.set(guild.id.stringValue, forKey: "currentWorkspace")
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
                    VoiceChannelRow(channel: channel, onOpenChat: { openChannel(channel) })
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
