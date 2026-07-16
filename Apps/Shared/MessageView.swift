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

    let channel: Channel

    @State private var draft = ""
    @State private var replyingTo: Message?
    @State private var editing: Message?
    @State private var pendingFiles: [PendingFile] = []
    @State private var messageToDelete: Message?
    @State private var isSending = false
    @State private var showMembers = false
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
            result.append(Entry(message: message, showsHeader: !groupsWithPrevious, dayLabel: dayLabel))
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
                // older history doesn't yank the view to the bottom.
                .onChange(of: session.messages(in: channel.id).last?.id) {
                    if let last = session.messages(in: channel.id).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .task(id: channel.id) {
                    session.activeChannelId = channel.id
                    session.recordVisit(channel)
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

            Divider()

            if session.canSendMessages(in: channel) {
                composerBanner
                pendingFilesRow
                slowmodeNotice

                HStack(spacing: 8) {
                    if session.canAttachFiles(in: channel) {
                        attachButton
                    }
                    TextField("Message \(channelTitle)", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .onSubmit(send)
                        .onChange(of: draft) { _, newValue in
                            if !newValue.isEmpty && editing == nil {
                                session.composerTyping(in: channel)
                            }
                        }
                    Button(action: send) {
                        Image(systemName: editing != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(!canSend || isSending || slowmodeRemaining > 0)
                }
                .padding(12)
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
            if let guildId = channel.guildId,
               session.permissions(in: channel).contains(.viewChannelMembers) {
                Button {
                    showMembers = true
                } label: {
                    Image(systemName: "person.2")
                }
                .sheet(isPresented: $showMembers) {
                    MemberListView(guildId: guildId)
                }
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
        _ = slowmodeTick
        return session.slowmodeRemaining(in: channel)
    }

    /// Bumped by a timer so the slowmode countdown re-renders each second.
    @State private var slowmodeTick = 0

    @ViewBuilder
    private var slowmodeNotice: some View {
        let interval = session.slowmodeInterval(in: channel)
        if interval > 0 {
            let remaining = slowmodeRemaining
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .task(id: remaining > 0) {
                while slowmodeRemaining > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    slowmodeTick += 1
                }
            }
        }
    }

    // MARK: Composer accessories

    @ViewBuilder
    private var attachButton: some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
            Image(systemName: "plus.circle")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
            Image(systemName: "plus.circle")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
    let message: Message
    let showsHeader: Bool
    let isOwn: Bool
    let onReact: (ReactionEmoji) -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsHeader {
                AvatarView(user: message.author, diameter: 36)
            } else {
                Color.clear.frame(width: 36, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let referenced = message.referencedMessage?.value {
                    replyPreview(referenced)
                }
                if showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.author?.displayName ?? "Unknown")
                            .font(.subheadline.bold())
                        if let timestamp = message.timestamp {
                            Text(timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if message.editedTimestamp != nil {
                            Text("edited")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let content = message.content, !content.isEmpty {
                    MessageContentText(content: content)
                }
                ForEach(message.attachments ?? []) { attachment in
                    AttachmentContent(attachment: attachment)
                }
                reactionPills
            }
            Spacer(minLength: 0)
        }
        .padding(.top, showsHeader ? 10 : 2)
        .contentShape(Rectangle())
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
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                onReply()
            }
            Button("Copy text", systemImage: "doc.on.doc") {
                copyText()
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            reaction.me == true ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.12),
                            in: Capsule()
                        )
                        .overlay {
                            if reaction.me == true {
                                Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
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
