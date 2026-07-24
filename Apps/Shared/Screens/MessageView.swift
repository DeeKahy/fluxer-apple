import SwiftUI
import FluxerKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif


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
    @State private var showGifPicker = false
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pasteboardHasImages = UIPasteboard.general.hasImages
    #else
    @State private var showFileImporter = false
    #endif

    /// Everything the pasteboard could hand us that we treat as an image.
    /// The first four upload as-is; the rest get re-encoded as PNG.
    private static let pastedImageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .tiff, .heic, .image]

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

    var body: some View {
        VStack(spacing: 0) {
            MessageTranscriptView(
                channel: channel,
                title: channelTitle,
                onReply: startReply,
                onEdit: startEdit,
                onDelete: { messageToDelete = $0 }
            )

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
        #if os(iOS)
        // changedNotification only fires for in-app copies; coming back from
        // another app with a fresh screenshot is caught by didBecomeActive.
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            pasteboardHasImages = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            pasteboardHasImages = UIPasteboard.general.hasImages
        }
        #endif
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
                #if os(iOS)
                if pasteboardHasImages {
                    pasteImageButton
                }
                #endif
                attachButton
            }
            HStack(alignment: .bottom, spacing: 4) {
                composerField
                gifButton
                    .padding(.bottom, 9)
                emojiButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 9)
            }
            .liquidGlass(cornerRadius: 22)
            Button(action: send) {
                Image(systemName: editing != nil ? "checkmark" : "arrow.up")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .liquidGlassCircle(
                        tint: canSend && slowmodeRemaining <= 0 ? Theme.accent : nil
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
                        #if os(iOS)
                        if pasteboardHasImages {
                            pasteImageButton
                        }
                        #endif
                        attachButton
                    }
                    gifButton
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
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .liquidGlass(cornerRadius: 14)
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
            .onKeyPress(.escape) {
                // Same as tapping the x on the reply/edit banner.
                if editing != nil {
                    editing = nil
                    draft = ""
                    return .handled
                }
                if replyingTo != nil {
                    replyingTo = nil
                    return .handled
                }
                return .ignored
            }
            .onChange(of: draft) { _, newValue in
                if !newValue.isEmpty && editing == nil {
                    session.composerTyping(in: channel)
                }
            }
            #if os(macOS)
            // Cmd+V with an image on the pasteboard attaches it; text-only
            // pasteboards fail the type check and paste into the field as usual.
            .onPasteCommand(of: Self.pastedImageTypes, perform: appendPastedImages)
            #endif
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

    private var gifButton: some View {
        Button {
            showGifPicker = true
        } label: {
            Text("GIF")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Theme.icon)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.icon.opacity(0.5), lineWidth: 1.3)
                )
                .frame(
                    width: desktopChrome ? 34 : nil,
                    height: desktopChrome ? 30 : nil
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .help("Send a GIF")
        .sheet(isPresented: $showGifPicker) {
            GifPickerSheet { gif in
                Task { await session.sendGif(gif, in: channel) }
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

    #if os(iOS)
    /// System paste control: reads the pasteboard without the "allow paste"
    /// prompt. Only shown while the pasteboard actually holds an image.
    private var pasteImageButton: some View {
        PasteButton(supportedContentTypes: Self.pastedImageTypes) { providers in
            appendPastedImages(providers)
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Theme.accent)
    }
    #endif

    @ViewBuilder
    private var attachButton: some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.icon)
                .frame(width: 36, height: 36)
                .liquidGlassCircle()
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
                .liquidGlassCircle()
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

    // MARK: Pasted images

    /// Turns image providers off the pasteboard into pending attachments.
    /// PNG/JPEG/GIF/WebP upload untouched; TIFF (mac screenshots), HEIC and
    /// anything else image-shaped is re-encoded as PNG so every client can
    /// render it.
    private func appendPastedImages(_ providers: [NSItemProvider]) {
        guard session.canAttachFiles(in: channel) else { return }
        let passthrough: [UTType] = [.png, .jpeg, .gif, .webP]
        let stamp = Int(Date().timeIntervalSince1970)
        for (index, provider) in providers.prefix(10).enumerated() {
            let match = Self.pastedImageTypes.first {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }
            guard let type = match else { continue }
            Task {
                guard var data = await Self.loadData(from: provider, type: type) else { return }
                var resolved = type
                if !passthrough.contains(type) {
                    guard let png = Self.pngData(from: data) else { return }
                    data = png
                    resolved = .png
                }
                pendingFiles.append(PendingFile(
                    filename: "pasted-\(stamp)-\(index).\(resolved.preferredFilenameExtension ?? "png")",
                    data: data,
                    contentType: resolved.preferredMIMEType ?? "image/png"
                ))
            }
        }
    }

    private nonisolated static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private nonisolated static func pngData(from data: Data) -> Data? {
        #if os(macOS)
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        #else
        UIImage(data: data)?.pngData()
        #endif
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

    /// Always reserves the same height whether or not anyone is typing, so
    /// the indicator popping in and out never shoves the message list up or
    /// down. Doubles as breathing room between the messages and the composer.
    private var typingIndicator: some View {
        let names = session.typingNames(in: channel.id)
        return HStack(spacing: 6) {
            if !names.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                Text(typingText(names))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func typingText(_ names: [String]) -> String {
        switch names.count {
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) and \(names[1]) are typing"
        default: return "Several people are typing"
        }
    }
}
