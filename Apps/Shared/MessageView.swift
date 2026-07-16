import SwiftUI
import FluxerKit

struct MessageView: View {
    @Environment(AppSession.self) private var session

    let channel: Channel

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

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
                            MessageRow(message: entry.message, showsHeader: entry.showsHeader)
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
                    await session.loadMessages(for: channel)
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message \(channelTitle)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .navigationTitle(channelTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func send() {
        let content = draft
        draft = ""
        composerFocused = true
        Task { await session.sendMessage(content, in: channel) }
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

private struct MessageRow: View {
    let message: Message
    let showsHeader: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsHeader {
                AvatarView(user: message.author, diameter: 36)
            } else {
                Color.clear.frame(width: 36, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
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
                    Text(content)
                        .textSelection(.enabled)
                }
                ForEach(message.attachments ?? []) { attachment in
                    AttachmentContent(attachment: attachment)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, showsHeader ? 10 : 2)
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
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay { ProgressView() }
                    .aspectRatio(aspectRatio, contentMode: .fit)
            }
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
