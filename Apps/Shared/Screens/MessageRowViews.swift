import SwiftUI
import FluxerKit

// The transcript row and its satellites, split out of MessageView.swift
// (issue #33). No behavior changes, only code motion.

/// The quick reaction choices in the message context menu.
private let quickReactions = ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F525}", "\u{2705}", "\u{1F440}"]

struct NewMessagesDivider: View {
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

struct DayDivider: View {
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

struct MessageRow: View {
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

    /// Local placeholder that hasn't been confirmed by the server yet;
    /// rendered dimmed with a clock until the echo swaps it out.
    private var isPending: Bool {
        session.isPendingSend(message)
    }

    /// The failure record when this placeholder's send failed; the row
    /// stays in the transcript with retry and discard controls.
    private var failedSend: AppSession.FailedSend? {
        session.failedSend(for: message)
    }

    /// Placeholders have a local-only id, so replying to or reacting to
    /// them would send the server an id it has never heard of.
    private var isLocalPlaceholder: Bool {
        isPending || failedSend != nil
    }

    var body: some View {
        rowContent
            // Swipe a row from right to left to reply. Gated to the mobile
            // shell; desktop uses the hover toolbar, and a left-to-right
            // swipe is left alone so it stays the navigation back gesture.
            .modifier(SwipeReplyModifier(enabled: !desktopChrome && !isLocalPlaceholder, onReply: onReply))
    }

    private var rowContent: some View {
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
                        if isPending {
                            Image(systemName: "clock")
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
                failedSendControls
            }
            Spacer(minLength: 0)
        }
        .opacity(isPending ? 0.45 : (failedSend != nil ? 0.6 : 1))
        .animation(.easeOut(duration: 0.25), value: isPending)
        .padding(.top, desktopChrome ? (showsHeader ? 8 : 1) : (showsHeader ? 10 : 2))
        .padding(.horizontal, desktopChrome ? 6 : 0)
        .padding(.bottom, desktopChrome ? 1 : 0)
        .background {
            if desktopChrome && hovering {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035))
            }
        }
        .overlay(alignment: .topTrailing) {
            if desktopChrome && hovering && !isLocalPlaceholder {
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
            if let failed = failedSend {
                Button("Retry send", systemImage: "arrow.clockwise") {
                    Task { await session.retrySend(failed) }
                }
                Button("Discard", systemImage: "trash", role: .destructive) {
                    session.discardFailedSend(nonce: failed.nonce)
                }
            } else if !isPending {
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
    }

    /// The failed marker under a send that didn't make it: reason plus
    /// tappable retry and discard, per issue #34.
    @ViewBuilder
    private var failedSendControls: some View {
        if let failed = failedSend {
            HStack(spacing: 12) {
                Label(failed.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.red)
                    .lineLimit(1)
                Button("Retry") {
                    Task { await session.retrySend(failed) }
                }
                .font(.caption.bold())
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                Button("Discard") {
                    session.discardFailedSend(nonce: failed.nonce)
                }
                .font(.caption.bold())
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
            }
            .padding(.top, 3)
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

/// Right-to-left swipe on a message row reveals a reply arrow and fires the
/// reply action once the drag passes the threshold. Only horizontal-dominant
/// left drags move the row, so vertical scrolling is untouched and the
/// system's left-edge back swipe keeps working.
private struct SwipeReplyModifier: ViewModifier {
    let enabled: Bool
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false

    private let threshold: CGFloat = -60

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .overlay(alignment: .trailing) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(armed ? Theme.accent : Theme.muted)
                        .opacity(Double(min(1, abs(offset) / abs(threshold))))
                        .padding(.trailing, 14)
                }
                // simultaneousGesture, NOT .gesture: a plain .gesture on
                // every row enters exclusive arbitration with the scroll
                // view's pan recognizer. On a mostly-vertical drag this
                // recognizer still claims the touch, and if the scroll view
                // cancels it mid-drag the onEnded never fires and the pan
                // gesture stays wedged until the channel is left and
                // reopened (the "can tap but can't scroll" freeze). Running
                // simultaneously takes it out of that arbitration entirely:
                // the pan can never be starved, and the row only translates
                // on horizontal-dominant drags.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            let dx = value.translation.width
                            // Vertical-dominant drag: this is a scroll, keep
                            // the row still and drop any partial offset.
                            guard dx < 0, abs(dx) > abs(value.translation.height) * 1.5 else {
                                if offset != 0 { offset = 0 }
                                armed = false
                                return
                            }
                            offset = max(dx, -90)
                            armed = offset <= threshold
                        }
                        .onEnded { _ in
                            if offset <= threshold { onReply() }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                offset = 0
                            }
                            armed = false
                        }
                )
                .sensoryFeedback(trigger: armed) { wasArmed, isArmed in
                    wasArmed || !isArmed ? nil : .impact(weight: .medium)
                }
        } else {
            content
        }
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
