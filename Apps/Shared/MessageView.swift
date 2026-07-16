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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages(in: channel.id)) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.messages(in: channel.id).count) {
                    if let last = session.messages(in: channel.id).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .task(id: channel.id) {
                    await session.loadMessages(for: channel)
                    if let last = session.messages(in: channel.id).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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

private struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(.tint.opacity(0.25))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(String((message.author?.displayName ?? "?").prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
            VStack(alignment: .leading, spacing: 2) {
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
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .textSelection(.enabled)
                }
                ForEach(message.attachments ?? []) { attachment in
                    Label(attachment.filename, systemImage: "paperclip")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
