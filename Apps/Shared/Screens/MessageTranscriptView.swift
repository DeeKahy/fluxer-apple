import SwiftUI
import FluxerKit

/// The scrolling message list for a channel: history, day dividers, the
/// unread marker, and all scroll behavior. Extracted from MessageView so
/// the chrome (composer, banners, toolbars) lives apart from the scroll
/// machinery.
///
/// Scroll behavior is built on the iOS 18 APIs instead of the old
/// sentinel-and-sleep workarounds: ScrollPosition for programmatic moves,
/// onScrollGeometryChange for a real distance-from-bottom signal, and
/// defaultScrollAnchor(.bottom) so size changes keep the transcript pinned.
struct MessageTranscriptView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.desktopChrome) private var desktopChrome

    let channel: Channel
    let title: String
    let onReply: (Message) -> Void
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void

    @State private var position = ScrollPosition(idType: Snowflake.self)
    @State private var unreadJumpDismissed = false

    /// Live scroll metrics, deliberately kept in a plain reference box
    /// instead of @State: they change on every scrolled pixel, nothing in
    /// the rendered body reads them, and routing them through SwiftUI
    /// state re-rendered the transcript per frame (the reply-gesture
    /// freezes). Only event closures read these.
    private final class MetricsBox {
        var distanceFromBottom: CGFloat = 0
        var viewportHeight: CGFloat = 0
    }
    @State private var metrics = MetricsBox()

    /// Close enough to the newest message to count as reading live.
    private var isAtBottom: Bool { metrics.distanceFromBottom < 40 }

    /// Scroll target for the new messages divider, distinct from message ids.
    private static let unreadDividerId = "new-messages-divider"

    private struct ScrollMetrics: Equatable {
        var distanceFromBottom: CGFloat
        var viewportHeight: CGFloat
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !session.canLoadOlderMessages(in: channel.id) {
                    welcomeHero
                }
                if session.canLoadOlderMessages(in: channel.id),
                   !session.messages(in: channel.id).isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear {
                            // The tracked scroll position keeps the current
                            // bottom-edge row anchored through the prepend,
                            // so no manual restore is needed.
                            Task { _ = await session.loadOlderMessages(for: channel) }
                        }
                }
                ForEach(entries) { entry in
                    if let dayLabel = entry.dayLabel {
                        DayDivider(label: dayLabel)
                    }
                    if entry.isFirstUnread {
                        NewMessagesDivider()
                            .id(Self.unreadDividerId)
                            // Once the divider has been on screen the
                            // jump pill has nothing left to offer.
                            .onAppear {
                                withAnimation { unreadJumpDismissed = true }
                            }
                    }
                    MessageRow(
                        message: entry.message,
                        showsHeader: entry.showsHeader,
                        isOwn: entry.message.author?.id == session.currentUser?.id,
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
            .scrollTargetLayout()
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollPosition($position, anchor: .bottom)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                distanceFromBottom: max(
                    0,
                    geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.containerSize.height - geometry.contentOffset.y
                ),
                viewportHeight: geometry.containerSize.height
            )
        } action: { old, new in
            // This fires for every scrolled pixel and every frame of a
            // keyboard or composer animation. Anything here that touches
            // observable state unconditionally re-renders the whole
            // transcript per frame and freezes the UI, so the metrics go
            // into the plain box and the remaining writes are guarded.
            metrics.distanceFromBottom = new.distanceFromBottom
            metrics.viewportHeight = new.viewportHeight
            // Belt and braces for viewport shrinks (composer growing a
            // line, banners appearing): if we were at the bottom and the
            // size-change anchor did NOT keep us pinned, re-pin. When the
            // anchor does its job the distance stays at zero and this
            // never runs.
            if new.viewportHeight < old.viewportHeight,
               old.distanceFromBottom < 40,
               new.distanceFromBottom > 1 {
                position.scrollTo(edge: .bottom)
            }
            updateResumeAnchor()
        }
        .overlay(alignment: .top) {
            unreadJumpPill
        }
        .overlay(alignment: .bottomTrailing) {
            jumpToBottomButton
                .animation(.easeOut(duration: 0.2), value: session.scrollAnchors[channel.id] != nil)
        }
        // Follow new messages while reading live, and always follow our own.
        .onChange(of: session.messages(in: channel.id).last?.id) { _, _ in
            let ownMessage = session.messages(in: channel.id).last?.author?.id == session.currentUser?.id
            if isAtBottom || ownMessage {
                position.scrollTo(edge: .bottom)
            }
        }
        .task(id: channel.id) {
            unreadJumpDismissed = false
            session.activeChannelId = channel.id
            session.recordVisit(channel)
            session.captureUnreadMarker(channel)
            await session.loadMessages(for: channel)
            session.markChannelRead(channel)
            // Resume where the reader left off, if they left meaningfully
            // scrolled up. One beat so the rows exist before the jump.
            if let saved = session.scrollAnchors[channel.id],
               session.messages(in: channel.id).contains(where: { $0.id == saved }) {
                try? await Task.sleep(for: .milliseconds(100))
                position.scrollTo(id: saved, anchor: .bottom)
            }
        }
        .onDisappear {
            if session.activeChannelId == channel.id {
                session.activeChannelId = nil
            }
        }
    }

    /// A resume spot is worth keeping once the reading position is more
    /// than about a screen and a half above the newest message. Anything
    /// closer reopens pinned to the bottom, and the saved anchor doubles
    /// as the jump-to-bottom button's visibility.
    private func updateResumeAnchor() {
        // Writing to the session invalidates every view observing it, so
        // only touch it when the anchor genuinely changes; this runs on
        // every scroll tick.
        if metrics.distanceFromBottom > max(metrics.viewportHeight * 1.5, 400) {
            if let id = position.viewID(type: Snowflake.self),
               session.scrollAnchors[channel.id] != id {
                session.scrollAnchors[channel.id] = id
            }
        } else if session.scrollAnchors[channel.id] != nil {
            session.scrollAnchors[channel.id] = nil
        }
    }

    // MARK: Overlays

    /// Floating jump back to the newest message, shown while a resume spot
    /// is armed, so its presence signals "you are not reading the latest".
    @ViewBuilder
    private var jumpToBottomButton: some View {
        if session.scrollAnchors[channel.id] != nil {
            Button {
                session.scrollAnchors[channel.id] = nil
                withAnimation(.easeOut(duration: 0.3)) {
                    position.scrollTo(edge: .bottom)
                }
                session.markChannelRead(channel)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
                    .liquidGlassCircle()
            }
            .buttonStyle(SquishButtonStyle())
            .padding(.trailing, 14)
            .padding(.bottom, 10)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    /// Floating pill offering a jump to the new messages divider. Only shows
    /// while the divider itself has stayed off screen, so a channel with a
    /// handful of unread never sees it.
    @ViewBuilder
    private var unreadJumpPill: some View {
        let unreadCount = entries.drop { !$0.isFirstUnread }.count
        if unreadCount > 0, !unreadJumpDismissed {
            HStack(spacing: 10) {
                Button {
                    withAnimation {
                        unreadJumpDismissed = true
                        position.scrollTo(id: Self.unreadDividerId, anchor: .top)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                        Text(unreadCount == 1 ? "1 new message" : "\(unreadCount) new messages")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation { unreadJumpDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Theme.accent, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            // The pill is an offer at the moment of opening, not a badge;
            // if it goes untouched it clears itself.
            .task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation { unreadJumpDismissed = true }
            }
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
