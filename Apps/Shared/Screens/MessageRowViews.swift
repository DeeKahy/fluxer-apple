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

struct MessageContentText: View {
    @Environment(AppSession.self) private var session

    let content: String
    var textColor: Color = Theme.messageText

    /// Spoiler indices tapped open in this segment; once revealed they
    /// stay revealed until the row is rebuilt, like the web client.
    @State private var revealedSpoilers: Set<Int> = []

    var body: some View {
        Text(session.renderMessageContent(content, revealedSpoilers: revealedSpoilers))
            .font(.system(size: 15))
            .foregroundStyle(textColor)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == MessageMarkdown.channelURLScheme else {
                    return .systemAction
                }
                if url.host() == "spoiler",
                   let indexPart = url.pathComponents.last,
                   let index = Int(indexPart) {
                    revealedSpoilers.insert(index)
                    return .handled
                }
                guard url.host() == "channel",
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
                            case .quote(let quoted):
                                HStack(alignment: .top, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.faint)
                                        .frame(width: 3)
                                    MessageContentText(content: quoted, textColor: Theme.soft)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 1)
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
                // UIKit pan recognizer, not a SwiftUI DragGesture. Both
                // SwiftUI flavors froze transcript scrolling on device: the
                // plain .gesture entered exclusive arbitration with the
                // scroll view's pan, and even .simultaneousGesture still
                // installs a SwiftUI gesture shim that could leave the pan
                // wedged after a cancelled touch (bisected to the commit
                // that introduced the swipe; the freeze survived the
                // simultaneous rewrite). The UIKit recognizer refuses to
                // begin unless the touch is already moving left and
                // horizontal-dominant, declares simultaneous recognition
                // with everything, and resets state on .cancelled/.failed,
                // so it structurally cannot starve or wedge the scroll pan.
                #if os(iOS)
                .gesture(SwipeReplyGesture(
                    offset: $offset,
                    armed: $armed,
                    threshold: threshold,
                    onReply: onReply
                ))
                #endif
                .sensoryFeedback(trigger: armed) { wasArmed, isArmed in
                    wasArmed || !isArmed ? nil : .impact(weight: .medium)
                }
        } else {
            content
        }
    }
}

#if os(iOS)
/// The swipe-to-reply pan as a real UIPanGestureRecognizer. The delegate
/// gates recognition at the UIKit level: the pan only begins when the touch
/// is already moving left and horizontal-dominant, so vertical scrolls make
/// this recognizer fail instantly instead of entering arbitration against
/// the scroll view. Simultaneous recognition is allowed with everything so
/// the scroll pan is never blocked, and .cancelled/.failed always reset the
/// row, so a torn-down touch cannot leave the transcript wedged.
private struct SwipeReplyGesture: UIGestureRecognizerRepresentable {
    @Binding var offset: CGFloat
    @Binding var armed: Bool
    let threshold: CGFloat
    let onReply: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .changed:
            let dx = recognizer.translation(in: recognizer.view).x
            offset = min(max(dx, -90), 0)
            armed = offset <= threshold
        case .ended:
            if offset <= threshold { onReply() }
            settle()
        case .cancelled, .failed:
            settle()
        default:
            break
        }
    }

    private func settle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            offset = 0
        }
        armed = false
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view
            else { return false }
            let velocity = pan.velocity(in: view)
            // Leftward and horizontal-dominant, otherwise fail so scrolls
            // and the system back swipe never see this recognizer at all.
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
