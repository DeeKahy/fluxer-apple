import SwiftUI
import FluxerKit

/// The scrolling message list for a channel. Deliberately minimal after
/// several rounds of clever scroll features made the experience worse:
/// no position saving, no geometry tracking, no jump buttons, and crucially
/// no programmatic scrolling. A single native mechanism does all the work:
/// defaultScrollAnchor(.bottom) aligns the bottom edge of the content on
/// first layout and on every size change, which opens at the newest message,
/// follows new messages, and holds position when older history is prepended,
/// all without ever issuing a scroll command from our code. An earlier
/// scrollPosition(id:) binding added a second, programmatic authority that
/// wedged the scroll view's pan gesture; see the anchor comment below.
/// Trade-off: when scrolled up reading history, a new message at the bottom
/// re-pins to the bottom. That is the price of having no jump button; revisit
/// only if it actually bothers the user, and never by reintroducing a
/// programmatic scroll authority without a fresh look at the freeze.
struct MessageTranscriptView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.desktopChrome) private var desktopChrome

    let channel: Channel
    let title: String
    let onReply: (Message) -> Void
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void

    /// Pagination stays disarmed until the initial load has settled. The
    /// lazy stack touches the top of the content during the first layout
    /// passes, which fired the history loader's onAppear on open and
    /// chain-loaded page after page in long channels, locking scrolling
    /// for seconds.
    @State private var paginationArmed = false

    /// The message a jump link is pointing at, briefly tinted after we scroll
    /// to it. Cleared on a timer.
    @State private var highlightedMessageId: Snowflake?
    /// Guards against two seek passes (the open task and a same-channel tap)
    /// running at once.
    @State private var seeking = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !session.canLoadOlderMessages(in: channel.id) {
                    welcomeHero
                }
                if paginationArmed,
                   session.canLoadOlderMessages(in: channel.id),
                   !session.messages(in: channel.id).isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear {
                            Task { _ = await session.loadOlderMessages(for: channel) }
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
                        isHighlighted: entry.message.id == highlightedMessageId,
                        onReact: { emoji in
                            Task { await session.toggleReaction(emoji, on: entry.message) }
                        },
                        onReply: { onReply(entry.message) },
                        onEdit: { onEdit(entry.message) },
                        onDelete: { onDelete(entry.message) }
                    )
                    .id(entry.message.id)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        // ONE scroll authority: the bottom anchor, applied on first layout
        // AND on every size change. Because it aligns the bottom EDGE of the
        // content it covers all three cases we need without a single
        // programmatic scroll: open at the newest message, follow new
        // messages arriving at the bottom, and hold position when older
        // history is prepended at the top (the bottom edge does not move, so
        // the viewport stays put). The previous scrollPosition(id:) binding
        // was a second, programmatic authority; writing it while the list
        // was still measuring rows (channel open) or while the viewport was
        // resizing (reply raises the banner and keyboard at once) left
        // UIScrollView's pan recognizer wedged until the channel was left
        // and reopened. Removing it is what unfreezes scrolling.
        .defaultScrollAnchor(.bottom)
        #if os(iOS)
        // Not .interactively: linking the pan gesture to the keyboard is
        // another way scrolling stops responding while the keyboard is up.
        .scrollDismissesKeyboard(.immediately)
        #endif
        // Follow the conversation to the bottom when the newest message is
        // our own send. This is the one deliberate scroll we keep, and it is
        // a ONE-SHOT imperative scrollTo, not a persistent binding: it fires
        // once per new own-message and never re-applies itself during a
        // resize, so it cannot wedge the pan gesture the way scrollPosition
        // did. Others' messages are left to the bottom anchor so reading
        // history is not yanked around.
        .onChange(of: session.messages(in: channel.id).last?.id) { _, newLast in
            guard let newLast,
                  session.messages(in: channel.id).last?.author?.id == session.currentUser?.id
            else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(newLast, anchor: .bottom)
            }
        }
        .task(id: channel.id) {
            paginationArmed = false
            session.activeChannelId = channel.id
            session.recordVisit(channel)
            session.captureUnreadMarker(channel)
            await session.loadMessages(for: channel)
            session.markChannelRead(channel)
            // If this channel was opened by a message link, scroll to and
            // highlight the target before arming pagination so the seek's own
            // history loads don't race the scroll-up loader.
            await seekToTarget(proxy)
            // Arm pagination only once layout has settled. The lazy stack
            // touches the top of the content during the first passes, so an
            // unguarded loader onAppear would chain-fire page loads on open.
            try? await Task.sleep(for: .milliseconds(300))
            paginationArmed = true
        }
        // A tap on a message link for the channel already on screen won't
        // re-run the task above (same id), so drive the seek from the target.
        .onChange(of: session.messageJumpTargets[channel.id]) { _, target in
            guard target != nil else { return }
            Task { await seekToTarget(proxy) }
        }
        .onDisappear {
            if session.activeChannelId == channel.id {
                session.activeChannelId = nil
            }
        }
        }
    }

    // MARK: Jump to message

    /// Loads the target message into the window if needed, scrolls to center it,
    /// and tints it for a couple of seconds. Consumes the pending target so it
    /// only fires once per link tap.
    private func seekToTarget(_ proxy: ScrollViewProxy) async {
        guard !seeking, let target = session.messageJumpTargets[channel.id] else { return }
        seeking = true
        defer { seeking = false }

        func loaded() -> Bool {
            session.messages(in: channel.id).contains { $0.id == target }
        }

        if !loaded() {
            // One window request centered on the message usually lands it;
            // if the server can't do that, page back through history instead.
            let landed = await session.loadMessagesAround(target, in: channel)
            if !landed {
                var pages = 0
                while !loaded(), session.canLoadOlderMessages(in: channel.id), pages < 12 {
                    _ = await session.loadOlderMessages(for: channel)
                    pages += 1
                }
            }
        }

        session.messageJumpTargets[channel.id] = nil
        guard loaded() else { return }
        // Let the freshly loaded rows lay out before scrolling to one.
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(target, anchor: .center)
        }
        highlightedMessageId = target
        try? await Task.sleep(for: .seconds(2))
        withAnimation(.easeOut(duration: 0.6)) {
            if highlightedMessageId == target { highlightedMessageId = nil }
        }
    }

    // MARK: Content

    private var welcomeHero: some View {
        // Mobile comp centers the hero; the desktop comp left-aligns it
        // with a bigger title.
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
            Text("Welcome to \(title)")
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

    // MARK: Entries

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
}
