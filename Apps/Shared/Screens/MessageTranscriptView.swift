import SwiftUI
import FluxerKit

/// The scrolling message list for a channel. Deliberately minimal after
/// several rounds of clever scroll features made the experience worse:
/// no position saving, no geometry tracking, no jump buttons. Two native
/// mechanisms do all the work:
/// - defaultScrollAnchor(.bottom): open at the newest message and stay
///   pinned through keyboard, composer and banner resizes.
/// - scrollPosition(id:): the system keeps the current row in place when
///   content changes (history prepends, messages arriving while reading
///   older history).
/// The only hand-rolled rule left is "follow the conversation": jump to a
/// new message when parked at the newest one or when it is our own.
struct MessageTranscriptView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.desktopChrome) private var desktopChrome

    let channel: Channel
    let title: String
    let onReply: (Message) -> Void
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void

    /// The row at the bottom edge, maintained by the system. Writing it
    /// scrolls there.
    @State private var scrolledId: Snowflake?

    /// Pagination stays disarmed until the initial load has settled. The
    /// lazy stack touches the top of the content during the first layout
    /// passes, which fired the history loader's onAppear on open and
    /// chain-loaded page after page in long channels, locking scrolling
    /// for seconds.
    @State private var paginationArmed = false

    var body: some View {
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
        // initialOffset ONLY. The anchor's size-change handling and the id
        // binding are two authorities both issuing scroll adjustments when
        // the viewport resizes; opening a reply (banner plus keyboard, two
        // resizes at once) left the scroll view stuck arbitrating between
        // them with its pan gesture disabled. The id binding alone keeps
        // the bottom row pinned through resizes.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition(id: $scrolledId, anchor: .bottom)
        #if os(iOS)
        // Not .interactively: linking the pan gesture to the keyboard is
        // another way scrolling stops responding while the keyboard is up.
        .scrollDismissesKeyboard(.immediately)
        #endif
        .onChange(of: session.messages(in: channel.id).last?.id) { oldLast, newLast in
            let ownMessage = session.messages(in: channel.id).last?.author?.id == session.currentUser?.id
            if scrolledId == nil || scrolledId == oldLast || ownMessage {
                scrolledId = newLast
            }
        }
        .task(id: channel.id) {
            scrolledId = nil
            paginationArmed = false
            session.activeChannelId = channel.id
            session.recordVisit(channel)
            session.captureUnreadMarker(channel)
            await session.loadMessages(for: channel)
            session.markChannelRead(channel)
            // Park on the newest message explicitly: until the user has
            // scrolled, the position binding is nil and a history prepend
            // has no row to hold onto, which let the view drift up into
            // the loader. Then arm pagination once layout has settled.
            scrolledId = session.messages(in: channel.id).last?.id
            try? await Task.sleep(for: .milliseconds(300))
            paginationArmed = true
        }
        .onDisappear {
            if session.activeChannelId == channel.id {
                session.activeChannelId = nil
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
