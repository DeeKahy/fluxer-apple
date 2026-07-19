import SwiftUI
import FluxerKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// The quick reaction choices in the message context menu.
private let quickReactions = ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F525}", "\u{2705}", "\u{1F440}"]

struct MessageView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.desktopChrome) private var desktopChrome

    let channel: Channel

    @State private var draft = ""
    @State private var replyingTo: Message?
    @State private var editing: Message?
    @State private var pendingFiles: [PendingFile] = []
    @State private var messageToDelete: Message?
    @State private var isSending = false
    @State private var showMembers = false
    @State private var showPins = false
    @State private var showEmojiPicker = false
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @State private var photoItems: [PhotosPickerItem] = []
    #else
    @State private var showFileImporter = false
    #endif

    struct PendingFile: Identifiable {
        let id = UUID()
        let filename: String
        let data: Data
        let contentType: String
    }

    private var channelTitle: String {
        if let name = channel.name, !name.isEmpty {
            return "#\(name)"
        }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }

    /// One rendered list entry: a message plus how it should appear.
    private struct Entry: Identifiable {
        let message: Message
        let showsHeader: Bool
        let dayLabel: String?
        var isFirstUnread = false
        var id: Snowflake { message.id }
    }

    /// Messages from the same author within a short window collapse under
    /// one header, and day changes get a labelled divider.
    private var entries: [Entry] {
        let messages = session.messages(in: channel.id)
        let calendar = Calendar.current
        let formatter = Self.dayFormatter
        var result: [Entry] = []
        result.reserveCapacity(messages.count)
        let unreadAfter = session.unreadMarkers[channel.id]
        var markedUnread = false
        var previous: Message?
        for message in messages {
            var dayLabel: String?
            let isNewDay: Bool
            if let timestamp = message.timestamp {
                if let previousTimestamp = previous?.timestamp {
                    isNewDay = !calendar.isDate(timestamp, inSameDayAs: previousTimestamp)
                } else {
                    isNewDay = previous == nil
                }
                if isNewDay {
                    dayLabel = formatter.string(from: timestamp)
                }
            } else {
                isNewDay = false
            }
            let groupsWithPrevious: Bool = {
                guard !isNewDay,
                      let previous,
                      previous.author?.id == message.author?.id,
                      message.referencedMessage == nil,
                      let previousTimestamp = previous.timestamp,
                      let timestamp = message.timestamp
                else { return false }
                return timestamp.timeIntervalSince(previousTimestamp) < 420
            }()
            var entry = Entry(message: message, showsHeader: !groupsWithPrevious, dayLabel: dayLabel)
            if !markedUnread, let unreadAfter, message.id > unreadAfter,
               message.author?.id != session.currentUser?.id {
                entry.isFirstUnread = true
                markedUnread = true
            }
            result.append(entry)
            previous = message
        }
        return result
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !session.canLoadOlderMessages(in: channel.id) {
                            // Mobile comp centers the hero; the desktop comp
                            // left-aligns it with a bigger title.
                            VStack(alignment: desktopChrome ? .leading : .center, spacing: 12) {
                                RoundedRectangle(cornerRadius: desktopChrome ? 16 : 18)
                                    .fill(Theme.heroTile)
                                    .frame(width: 60, height: 60)
                                    .overlay {
                                        if channel.guildId != nil {
                                            Text("#")
                                                .font(.system(size: desktopChrome ? 26 : 30, weight: desktopChrome ? .heavy : .regular))
                                                .foregroundStyle(Theme.accentSoft)
                                        } else {
                                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                                .font(.system(size: 24))
                                                .foregroundStyle(Theme.accentSoft)
                                        }
                                    }
                                Text("Welcome to \(channelTitle)")
                                    .font(.system(size: desktopChrome ? 26 : 22, weight: .heavy))
                                    .foregroundStyle(Theme.text)
                                    .multilineTextAlignment(desktopChrome ? .leading : .center)
                                if let topic = channel.topic, !topic.isEmpty {
                                    Text(topic)
                                        .font(.system(size: desktopChrome ? 15 : 14))
                                        .foregroundStyle(Theme.secondary)
                                        .multilineTextAlignment(desktopChrome ? .leading : .center)
                                } else {
                                    Text("This is the very beginning of the conversation.")
                                        .font(.system(size: desktopChrome ? 15 : 14))
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: desktopChrome ? .leading : .center)
                            .padding(.vertical, 22)
                            .padding(.horizontal, desktopChrome ? 10 : 0)
                        }
                        if session.canLoadOlderMessages(in: channel.id),
                           !session.messages(in: channel.id).isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .onAppear {
                                    Task {
                                        if let anchor = await session.loadOlderMessages(for: channel) {
                                            proxy.scrollTo(anchor, anchor: .top)
                                        }
                                    }
                                }
                        }
                        ForEach(entries) { entry in
                            if let dayLabel = entry.dayLabel {
                                DayDivider(label: dayLabel)
                            }
                            if entry.isFirstUnread {
                                NewMessagesDivider()
                            }
                            MessageRow(
                                message: entry.message,
                                showsHeader: entry.showsHeader,
                                isOwn: entry.message.author?.id == session.currentUser?.id,
                                onReact: { emoji in
                                    Task { await session.toggleReaction(emoji, on: entry.message) }
                                },
                                onReply: { startReply(entry.message) },
                                onEdit: { startEdit(entry.message) },
                                onDelete: { messageToDelete = entry.message }
                            )
                            .id(entry.message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                // Content starts pinned to the newest message, which also
                // survives lazy row sizing, unlike a manual scrollTo.
                .defaultScrollAnchor(.bottom)
                // Keyed on the newest id, not the count, so prepending
                // older history doesn't yank the view to the bottom. The
                // scroll is deferred a beat so it never runs inside the
                // same layout pass that inserted the row.
                .onChange(of: session.messages(in: channel.id).last?.id) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        if let last = session.messages(in: channel.id).last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .task(id: channel.id) {
                    session.activeChannelId = channel.id
                    session.recordVisit(channel)
                    session.captureUnreadMarker(channel)
                    await session.loadMessages(for: channel)
                    session.markChannelRead(channel)
                }
                .onDisappear {
                    if session.activeChannelId == channel.id {
                        session.activeChannelId = nil
                    }
                }
            }

            typingIndicator

            // The desktop comp's composer floats on the background with no
            // separator line above it.
            if !desktopChrome {
                Divider()
            }

            if session.canSendMessages(in: channel) {
                composerBanner
                pendingFilesRow
                slowmodeNotice

                if desktopChrome {
                    desktopComposer
                } else {
                    mobileComposer
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text("You don't have permission to send messages in this channel.")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.quaternary.opacity(0.5))
            }
        }
        .navigationTitle(channelTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !desktopChrome {
                if channel.type == .dm || channel.type == .groupDM {
                    Button {
                        Task { await session.startCall(in: channel) }
                    } label: {
                        Image(systemName: "phone")
                    }
                    .disabled(session.voice.connectedChannelId == channel.id)
                }
                if channel.type == .guildVoice {
                    Button {
                        Task { await session.joinVoice(channel) }
                    } label: {
                        Image(systemName: "phone")
                    }
                    .disabled(session.voice.connectedChannelId == channel.id)
                }
                Button {
                    showPins = true
                } label: {
                    Image(systemName: "pin")
                }
                if channel.guildId != nil,
                   session.permissions(in: channel).contains(.viewChannelMembers) {
                    Button {
                        showMembers = true
                    } label: {
                        Image(systemName: "person.2")
                    }
                }
            }
        }
        .sheet(isPresented: $showPins) {
            PinsView(channel: channel)
        }
        .sheet(isPresented: $showMembers) {
            if let guildId = channel.guildId {
                MemberListView(guildId: guildId)
            }
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(
                get: { messageToDelete != nil },
                set: { if !$0 { messageToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let message = messageToDelete {
                    Task { await session.deleteMessage(message) }
                }
                messageToDelete = nil
            }
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(10) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                pendingFiles.append(
                    PendingFile(filename: url.lastPathComponent, data: data, contentType: contentType)
                )
            }
        }
        #endif
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingFiles.isEmpty
    }

    private var slowmodeRemaining: TimeInterval {
        session.slowmodeRemaining(in: channel)
    }

    @ViewBuilder
    private var slowmodeNotice: some View {
        let interval = session.slowmodeInterval(in: channel)
        if interval > 0 {
            // TimelineView redraws just this row each second; driving the
            // countdown by mutating view state destabilised the whole screen.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, session.slowmodeUntil[channel.id]?.timeIntervalSince(context.date) ?? 0)
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.caption)
                    if remaining > 0 {
                        Text("Slowmode: you can send again in \(Int(remaining.rounded(.up)))s")
                            .font(.caption)
                            .monospacedDigit()
                    } else {
                        Text("Slowmode is on: one message every \(interval)s")
                            .font(.caption)
                    }
                    Spacer()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: Composers

    private var mobileComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if session.canAttachFiles(in: channel) {
                attachButton
            }
            HStack(alignment: .bottom, spacing: 4) {
                composerField
                emojiButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 9)
            }
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 18))
            Button(action: send) {
                Image(systemName: editing != nil ? "checkmark" : "arrow.up")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        canSend && slowmodeRemaining <= 0 ? Theme.accent : Theme.bubble,
                        in: Circle()
                    )
            }
            .buttonStyle(SquishButtonStyle())
            .disabled(!canSend || isSending || slowmodeRemaining > 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The comp's boxed desktop composer: a formatting strip on top and
    /// the input row with attach, emoji, and a square send key below.
    private var desktopComposer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                markerButton("bold", marker: "**") {
                    Text("B").font(.system(size: 13, weight: .bold))
                }
                markerButton("italic", marker: "*") {
                    Text("i").font(.system(size: 13)).italic()
                }
                markerButton("strikethrough", marker: "~~") {
                    Text("S").font(.system(size: 13)).strikethrough()
                }
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 15)
                markerButton("code", marker: "`") {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11))
                }
                markerButton("code block", marker: "```\n") {
                    Image(systemName: "square.topthird.inset.filled")
                        .font(.system(size: 11))
                }
                Spacer()
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
            HStack(alignment: .bottom, spacing: 8) {
                composerField
                    .padding(.vertical, 3)
                HStack(spacing: 4) {
                    if session.canAttachFiles(in: channel) {
                        attachButton
                    }
                    emojiButton
                    Button(action: send) {
                        Image(systemName: editing != nil ? "checkmark" : "paperplane.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                canSend && slowmodeRemaining <= 0 ? Theme.accent : Theme.sendIdle,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(SquishButtonStyle())
                    .disabled(!canSend || isSending || slowmodeRemaining > 0)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 20)
    }

    private var composerField: some View {
        TextField("Message \(channelTitle)", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .font(.system(size: 15))
            .foregroundStyle(Theme.text)
            .padding(.leading, desktopChrome ? 4 : 14)
            .padding(.vertical, 9)
            .focused($composerFocused)
            .onSubmit(send)
            .onChange(of: draft) { _, newValue in
                if !newValue.isEmpty && editing == nil {
                    session.composerTyping(in: channel)
                }
            }
    }

    private var emojiButton: some View {
        Button {
            showEmojiPicker = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: desktopChrome ? 16 : 19))
                .foregroundStyle(Theme.icon)
                .frame(
                    width: desktopChrome ? 30 : nil,
                    height: desktopChrome ? 30 : nil
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet { emoji in
                draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + emoji.messageToken + " "
            }
            .preferredColorScheme(.dark)
        }
    }

    /// Appends a markdown marker; click once to open, again to close.
    private func markerButton<C: View>(
        _ help: String,
        marker: String,
        @ViewBuilder label: () -> C
    ) -> some View {
        Button {
            draft += marker
            composerFocused = true
        } label: {
            label()
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .help(help)
    }

    // MARK: Composer accessories

    @ViewBuilder
    private var attachButton: some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.icon)
                .frame(width: 36, height: 36)
                .background(Theme.bubble, in: Circle())
        }
        .buttonStyle(SquishButtonStyle())
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for (index, item) in items.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first
                    let ext = type?.preferredFilenameExtension ?? "jpg"
                    let mime = type?.preferredMIMEType ?? "image/jpeg"
                    pendingFiles.append(
                        PendingFile(
                            filename: "photo-\(Int(Date().timeIntervalSince1970))-\(index).\(ext)",
                            data: data,
                            contentType: mime
                        )
                    )
                }
            }
        }
        #else
        Button {
            showFileImporter = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.icon)
                .frame(width: 36, height: 36)
                .background(Theme.bubble, in: Circle())
        }
        .buttonStyle(SquishButtonStyle())
        #endif
    }

    @ViewBuilder
    private var composerBanner: some View {
        if let editing {
            bannerRow(icon: "pencil", text: "Editing message") {
                self.editing = nil
                draft = ""
            }
        } else if let replyingTo {
            bannerRow(
                icon: "arrowshape.turn.up.left",
                text: "Replying to \(replyingTo.author?.displayName ?? "message")"
            ) {
                self.replyingTo = nil
            }
        }
    }

    private func bannerRow(icon: String, text: String, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button {
                cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pendingFilesRow: some View {
        if !pendingFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pendingFiles) { file in
                        HStack(spacing: 6) {
                            if file.contentType.hasPrefix("image/"), let image = PlatformImage(data: file.data) {
                                #if os(macOS)
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                #else
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                #endif
                            } else {
                                Image(systemName: "doc")
                            }
                            Text(file.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: 120)
                            Button {
                                pendingFiles.removeAll { $0.id == file.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }

    // MARK: Actions

    private func startReply(_ message: Message) {
        editing = nil
        replyingTo = message
        composerFocused = true
    }

    private func startEdit(_ message: Message) {
        replyingTo = nil
        editing = message
        draft = message.content ?? ""
        composerFocused = true
    }

    private func send() {
        guard canSend, !isSending, slowmodeRemaining <= 0 else { return }
        let content = draft
        let reply = replyingTo?.id
        let files = pendingFiles.map {
            APIClient.UploadFile(filename: $0.filename, data: $0.data, contentType: $0.contentType)
        }
        let editTarget = editing
        draft = ""
        replyingTo = nil
        editing = nil
        pendingFiles = []
        composerFocused = true
        isSending = true
        Task {
            if let editTarget {
                await session.editMessage(editTarget, content: content)
            } else {
                await session.sendMessage(content, in: channel, replyTo: reply, files: files)
            }
            isSending = false
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        let names = session.typingNames(in: channel.id)
        if !names.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(typingText(names))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func typingText(_ names: [String]) -> String {
        switch names.count {
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) and \(names[1]) are typing"
        default: return "Several people are typing"
        }
    }
}

private struct NewMessagesDivider: View {
    var body: some View {
        HStack {
            Rectangle().fill(Color.red.opacity(0.6)).frame(height: 1)
            Text("New messages")
                .font(.caption2.bold())
                .foregroundStyle(.red)
                .fixedSize()
            Rectangle().fill(Color.red.opacity(0.6)).frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

private struct DayDivider: View {
    let label: String

    var body: some View {
        HStack {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 12)
    }
}

private struct MessageContentText: View {
    @Environment(AppSession.self) private var session

    let content: String

    var body: some View {
        Text(session.renderMessageContent(content))
            .font(.system(size: 15))
            .foregroundStyle(Theme.messageText)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == MessageMarkdown.channelURLScheme,
                      url.host() == "channel",
                      let idPart = url.pathComponents.last,
                      let id = Snowflake(string: idPart),
                      let channel = session.findChannel(id)
                else {
                    return .systemAction
                }
                session.channelJump = channel
                return .handled
            })
    }
}

private struct MessageRow: View {
    @Environment(AppSession.self) private var session
    @Environment(\.desktopChrome) private var desktopChrome

    let message: Message
    let showsHeader: Bool
    let isOwn: Bool
    let onReact: (ReactionEmoji) -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var profileUser: User?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsHeader {
                Button {
                    profileUser = message.author
                } label: {
                    AvatarView(user: message.author, diameter: desktopChrome ? 40 : 36)
                }
                .buttonStyle(SquishButtonStyle())
                .tapTarget()
            } else {
                Color.clear
                    .frame(width: desktopChrome ? 40 : 36, height: 1)
                    .overlay(alignment: .topTrailing) {
                        if desktopChrome, hovering, let timestamp = message.timestamp {
                            Text(timestamp, style: .time)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.sectionMuted)
                                .fixedSize()
                                .padding(.top, 3)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let referenced = message.referencedMessage?.value {
                    replyPreview(referenced)
                }
                if showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(message.author?.displayName ?? "Unknown")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.nameColor(for: message.author?.id))
                            .contentShape(Rectangle().inset(by: -4))
                            .onTapGesture {
                                profileUser = message.author
                            }
                        if let timestamp = message.timestamp {
                            Text(timestamp, style: .time)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                        }
                        if message.editedTimestamp != nil {
                            Text("edited")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                if let content = message.content, !content.isEmpty {
                    if let emojiIds = MessageMarkdown.emojiOnlyIds(content) {
                        HStack(spacing: 4) {
                            ForEach(Array(emojiIds.enumerated()), id: \.offset) { _, id in
                                RemoteImage(url: MediaURLs.customEmoji(ReactionEmoji(id: id, name: "e"))) {
                                    Color.clear
                                }
                                .frame(width: 40, height: 40)
                            }
                        }
                        .padding(.top, 2)
                    } else {
                        ForEach(Array(MessageMarkdown.segments(content).enumerated()), id: \.offset) { _, segment in
                            switch segment {
                            case .text(let text):
                                MessageContentText(content: text)
                            case .codeBlock(let code):
                                ScrollView(.horizontal, showsIndicators: false) {
                                    Text(code)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                }
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                ForEach(message.attachments ?? []) { attachment in
                    AttachmentContent(attachment: attachment)
                }
                ForEach(Array((message.embeds ?? []).prefix(3).enumerated()), id: \.offset) { _, embed in
                    EmbedView(embed: embed)
                }
                ForEach(MessageMarkdown.inviteCodes(message.content ?? ""), id: \.self) { code in
                    InviteCardView(code: code)
                }
                reactionPills
            }
            Spacer(minLength: 0)
        }
        .padding(.top, desktopChrome ? (showsHeader ? 8 : 1) : (showsHeader ? 10 : 2))
        .padding(.horizontal, desktopChrome ? 6 : 0)
        .padding(.bottom, desktopChrome ? 1 : 0)
        .background {
            if desktopChrome && hovering {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035))
            }
        }
        .overlay(alignment: .topTrailing) {
            if desktopChrome && hovering {
                hoverToolbar
            }
        }
        .zIndex(hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .sheet(item: $profileUser) { user in
            ProfileSheet(user: user)
        }
        .contextMenu {
            ControlGroup {
                ForEach(quickReactions.prefix(4), id: \.self) { emoji in
                    Button(emoji) {
                        onReact(ReactionEmoji(name: emoji))
                    }
                }
            }
            Menu("More reactions") {
                ForEach(quickReactions, id: \.self) { emoji in
                    Button(emoji) {
                        onReact(ReactionEmoji(name: emoji))
                    }
                }
            }
            actionItems
        }
    }

    /// Shared message actions, used by the context menu and the desktop
    /// hover toolbar's overflow menu.
    @ViewBuilder
    private var actionItems: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") {
            onReply()
        }
        Button("Copy text", systemImage: "doc.on.doc") {
            copyText()
        }
        Button("Save message", systemImage: "bookmark") {
            Task { await session.setSaved(message, saved: true) }
        }
        if canPin {
            if message.pinned == true {
                Button("Unpin", systemImage: "pin.slash") {
                    Task { await session.setPinned(message, pinned: false) }
                }
            } else {
                Button("Pin message", systemImage: "pin") {
                    Task { await session.setPinned(message, pinned: true) }
                }
            }
        }
        if isOwn {
            Divider()
            Button("Edit", systemImage: "pencil") {
                onEdit()
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }

    /// Floating quick actions revealed on hover, comp's mtools bar.
    private var hoverToolbar: some View {
        HStack(spacing: 1) {
            ForEach(quickReactions.prefix(3), id: \.self) { emoji in
                Button {
                    onReact(ReactionEmoji(name: emoji))
                } label: {
                    Text(emoji)
                        .font(.system(size: 15))
                        .frame(width: 30, height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(SquishButtonStyle())
            }
            Button {
                onReply()
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.icon)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(SquishButtonStyle())
            .help("Reply")
            Menu {
                actionItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.icon)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
        }
        .padding(3)
        .background(Theme.sidebarField, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 9, y: 6)
        .offset(y: -16)
        .padding(.trailing, 12)
    }

    private func replyPreview(_ referenced: Message) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.caption2)
            Text(referenced.author?.displayName ?? "Unknown")
                .font(.caption.bold())
            Text(referenced.content ?? "attachment")
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var reactionPills: some View {
        let reactions = message.reactions ?? []
        if !reactions.isEmpty {
            HStack(spacing: 6) {
                ForEach(reactions, id: \.emoji.key) { reaction in
                    Button {
                        onReact(reaction.emoji)
                    } label: {
                        HStack(spacing: 4) {
                            if reaction.emoji.id != nil {
                                RemoteImage(url: MediaURLs.customEmoji(reaction.emoji)) {
                                    Text(":\(reaction.emoji.name):").font(.caption2)
                                }
                                .frame(width: 16, height: 16)
                            } else {
                                Text(reaction.emoji.name)
                                    .font(.footnote)
                            }
                            Text("\(reaction.count)")
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            reaction.me == true ? Theme.accent.opacity(0.18) : Theme.surface,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                reaction.me == true ? Theme.accent.opacity(0.55) : Theme.hairline,
                                lineWidth: 1
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private var canPin: Bool {
        guard let channel = session.findChannel(message.channelId) else { return false }
        let perms = session.permissions(in: channel)
        return perms.contains(.pinMessages) || perms.contains(.manageMessages)
    }

    private func copyText() {
        guard let content = message.content else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        #else
        UIPasteboard.general.string = content
        #endif
    }
}

private struct AttachmentContent: View {
    let attachment: Attachment

    private var isImage: Bool {
        attachment.contentType?.hasPrefix("image/") == true
    }

    private var imageURL: URL? {
        (attachment.proxyUrl ?? attachment.url).flatMap(URL.init(string:))
    }

    @State private var showViewer = false

    var body: some View {
        if isImage, let url = imageURL {
            RemoteImage(url: url) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay { ProgressView() }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 320, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
            .onTapGesture { showViewer = true }
            .sheet(isPresented: $showViewer) {
                ImageViewerSheet(url: url, filename: attachment.filename)
            }
        } else {
            Label(attachment.filename, systemImage: "paperclip")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = attachment.width, let height = attachment.height, height > 0 else {
            return 4 / 3
        }
        return CGFloat(width) / CGFloat(height)
    }
}
