import SwiftUI
import FluxerKit

/// Compact message rendering for pins, saved messages, and mentions lists.
struct MessageSnippetRow: View {
    @Environment(AppSession.self) private var session

    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: message.author, diameter: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.author?.displayName ?? "Unknown")
                        .font(.caption.bold())
                    if let timestamp = message.timestamp {
                        Text(timestamp, format: .dateTime.day().month().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let content = message.content, !content.isEmpty {
                    Text(session.renderMessageContent(content))
                        .font(.callout)
                        .lineLimit(4)
                }
                if let first = message.attachments?.first {
                    Label(first.filename, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let channel = session.findChannel(message.channelId) {
                session.channelJump = channel
            }
        }
    }
}

/// Pinned messages of one channel.
struct PinsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let channel: Channel

    @State private var pins: [Message]?

    var body: some View {
        NavigationStack {
            List {
                if let pins {
                    if pins.isEmpty {
                        Text("No pinned messages.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pins) { message in
                        MessageSnippetRow(message: message)
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Pinned messages")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task {
                pins = await session.pinnedMessages(in: channel)
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

/// Saved messages and recent mentions share one list shape.
struct MessageFeedView: View {
    @Environment(AppSession.self) private var session

    enum Feed {
        case saved
        case mentions

        var title: String {
            switch self {
            case .saved: return "Saved messages"
            case .mentions: return "Recent mentions"
            }
        }
    }

    let feed: Feed

    @State private var messages: [Message]?

    private var emptyText: String {
        feed == .saved ? "Nothing saved yet." : "No recent mentions."
    }

    var body: some View {
        List {
            if let loaded = messages {
                if loaded.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
                ForEach(loaded) { message in
                    row(message)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .navigationTitle(feed.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if feed == .mentions, let loaded = messages, !loaded.isEmpty {
                Button("Mark all read") {
                    Task {
                        await session.markMentionsRead(loaded)
                        messages = []
                    }
                }
            }
        }
        .task {
            messages = feed == .saved ? await session.savedMessages() : await session.recentMentions()
        }
    }

    private func row(_ message: Message) -> some View {
        MessageSnippetRow(message: message)
            .contextMenu {
                if feed == .saved {
                    Button("Unsave", systemImage: "bookmark.slash") {
                        Task {
                            await session.setSaved(message, saved: false)
                            self.messages?.removeAll { $0.id == message.id }
                        }
                    }
                } else {
                    Button("Dismiss", systemImage: "bell.slash") {
                        Task {
                            await session.dismissMention(message)
                            self.messages?.removeAll { $0.id == message.id }
                        }
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if feed == .mentions {
                    Button("Dismiss", systemImage: "bell.slash") {
                        Task {
                            await session.dismissMention(message)
                            self.messages?.removeAll { $0.id == message.id }
                        }
                    }
                    .tint(.red)
                }
            }
    }
}

/// Profile sheet shown when tapping an avatar.
struct ProfileSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let user: User

    @State private var profile: APIClient.UserProfile?
    @State private var requestSent = false
    @State private var friendRequestFailed = false

    var body: some View {
        VStack(spacing: 16) {
            header
            bioSection
            actionButtons
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .task {
            profile = await session.profile(of: user.id)
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 360)
        #endif
        .presentationDetents([.medium])
    }

    private var header: some View {
        VStack(spacing: 8) {
            AvatarView(user: user, diameter: 72)
                .overlay(alignment: .bottomTrailing) {
                    PresenceDot(status: session.presenceStatus(for: user.id))
                }
                .padding(.top, 24)
            Text(user.displayName)
                .font(.title2.bold())
            if let username = user.username {
                Text(username)
                    .foregroundStyle(.secondary)
            }
            if let pronouns = profile?.pronouns, !pronouns.isEmpty {
                Text(pronouns)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bioSection: some View {
        if let bio = profile?.bio, !bio.isEmpty {
            Text(bio)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if user.id != session.currentUser?.id {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            if let dm = await session.openDM(with: user.id) {
                                dismiss()
                                session.channelJump = dm
                            }
                        }
                    } label: {
                        Label("Message", systemImage: "bubble.left")
                    }
                    .buttonStyle(.borderedProminent)
                    if session.relationships[user.id] == nil {
                        Button {
                            Task {
                                friendRequestFailed = false
                                requestSent = await session.sendFriendRequest(to: user.id)
                                friendRequestFailed = !requestSent
                            }
                        } label: {
                            Label(
                                requestSent ? "Request sent" : "Add friend",
                                systemImage: requestSent ? "checkmark" : "person.badge.plus"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(requestSent)
                    } else if session.relationships[user.id]?.type == .friend {
                        Label("Friends", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if session.relationships[user.id]?.type == .outgoingRequest {
                        Label("Request pending", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                }
                if friendRequestFailed, let error = session.friendRequestError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }
        }
    }
}

/// Full screen image viewer with zoom.
struct ImageViewerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL
    let filename: String

    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                RemoteImage(url: url) {
                    ProgressView()
                }
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(zoom)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = max(1, value.magnification)
                        }
                        .onEnded { _ in
                            withAnimation { zoom = 1 }
                        }
                )
            }
            .background(.black)
            .navigationTitle(filename)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button("Done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }
}

/// Custom emoji picker for the composer.
struct EmojiPickerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let onPick: (GuildEmoji) -> Void

    private let columns = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.emojiByGuild.isEmpty {
                        Text("No custom emoji in your guilds.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(session.emojiByGuild, id: \.guild.id) { group in
                        Text(group.guild.name)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(group.emojis) { emoji in
                                Button {
                                    onPick(emoji)
                                    dismiss()
                                } label: {
                                    RemoteImage(url: MediaURLs.customEmoji(emoji.asReactionEmoji)) {
                                        Text(":\(emoji.name):")
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                                .help(":\(emoji.name):")
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Emoji")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
        .presentationDetents([.medium, .large])
    }
}

/// Active login sessions, with revocation.
struct SessionsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [APIClient.AuthSession]?

    var body: some View {
        NavigationStack {
            List {
                if let sessions {
                    ForEach(sessions) { authSession in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(describe(authSession))
                                    if authSession.current {
                                        Text("This device")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                                    }
                                }
                                if let ip = authSession.maskedIp {
                                    Text(ip)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !authSession.current {
                                Button("Log out", role: .destructive) {
                                    Task {
                                        if await session.revokeSession(authSession) {
                                            self.sessions?.removeAll { $0.idHash == authSession.idHash }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task {
                sessions = await session.authSessions()
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 380)
        #endif
    }

    private func describe(_ authSession: APIClient.AuthSession) -> String {
        let info = authSession.clientInfo
        let parts = [info?.platform, info?.os, info?.browser].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown device" : parts.joined(separator: ", ")
    }
}

/// Invite card rendered under messages containing fluxer.gg links.
struct InviteCardView: View {
    @Environment(AppSession.self) private var session

    let code: String

    private enum LoadState {
        case loading
        case invalid
        case loaded(APIClient.Invite)
    }

    @State private var state: LoadState = .loading
    @State private var joining = false

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .loading:
                ProgressView()
                Text("Resolving invite")
                    .foregroundStyle(.secondary)
            case .invalid:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                Text("Invalid or expired invite")
                    .foregroundStyle(.secondary)
            case .loaded(let invite):
                inviteContent(invite)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
        .task(id: code) {
            if let invite = await session.inviteInfo(code: code) {
                state = .loaded(invite)
            } else {
                state = .invalid
            }
        }
    }

    @ViewBuilder
    private func inviteContent(_ invite: APIClient.Invite) -> some View {
        let guildId = invite.guild?.id
        let isMember = guildId.map { session.isMember(ofGuild: $0) } ?? false

        if let guild = invite.guild {
            RemoteImage(url: guild.iconURL(size: 56)) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.25))
                    .overlay {
                        Text(String(guild.name.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundStyle(.tint)
                    }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        VStack(alignment: .leading, spacing: 1) {
            Text(invite.guild?.name ?? "A Fluxer guild")
                .font(.callout.bold())
                .lineLimit(1)
            if let channelName = invite.channel?.name {
                Text("#\(channelName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isMember {
                Text("You're a member")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 8)

        if isMember {
            Button("Open") {
                openLocally(invite)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(joining ? "Joining" : "Join") {
                joining = true
                Task {
                    await session.joinAndJump(code: code)
                    joining = false
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(joining)
        }
    }

    private func openLocally(_ invite: APIClient.Invite) {
        guard let guildId = invite.guild?.id,
              let guild = session.guilds.first(where: { $0.id == guildId })
        else { return }
        let channel = invite.channel.flatMap { inviteChannel in
            guild.channels?.first { $0.id == inviteChannel.id }
        } ?? session.defaultChannel(for: guild)
        if let channel {
            session.channelJump = channel
        }
    }
}

/// Rich embed rendering under messages.
struct EmbedView: View {
    let embed: Embed

    @State private var viewerURL: URL?

    private var barColor: Color {
        guard let color = embed.color else { return .secondary.opacity(0.4) }
        return Color(
            red: Double((color >> 16) & 0xFF) / 255,
            green: Double((color >> 8) & 0xFF) / 255,
            blue: Double(color & 0xFF) / 255
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                if let author = embed.author?.name {
                    Text(author)
                        .font(.caption.bold())
                }
                if let title = embed.title {
                    if let urlString = embed.url, let url = URL(string: urlString) {
                        Link(title, destination: url)
                            .font(.callout.bold())
                    } else {
                        Text(title)
                            .font(.callout.bold())
                    }
                }
                if let description = embed.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }
                if let media = embed.image ?? (embed.title == nil && embed.description == nil ? embed.thumbnail : nil),
                   let urlString = media.proxyUrl ?? media.url,
                   let url = URL(string: urlString) {
                    RemoteImage(url: url) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .frame(height: 120)
                    }
                    .aspectRatio(mediaAspect(media), contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let footer = embed.footer?.text {
                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 400, alignment: .leading)
        .padding(.top, 4)
    }

    private func mediaAspect(_ media: EmbedMedia) -> CGFloat {
        guard let width = media.width, let height = media.height, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }
}
