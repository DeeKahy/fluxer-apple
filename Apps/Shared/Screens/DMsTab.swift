import SwiftUI
import FluxerKit

struct DMsTab: View {
    @Environment(AppSession.self) private var session

    let openChannel: (Channel) -> Void

    @State private var showFriends = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(session.privateChannels) { channel in
                    dmRow(channel)
                }
                if session.privateChannels.isEmpty {
                    Text("No conversations yet")
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle("Messages")
        .toolbar {
            if !session.readStatesSynced {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.muted)
            }
            Button {
                showFriends = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
        }
        .sheet(isPresented: $showFriends) {
            NavigationStack {
                FriendsView()
                    .toolbar {
                        Button("Done") { showFriends = false }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func dmRow(_ channel: Channel) -> some View {
        let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
            ?? channel.recipients?.first
        let unread = session.isUnread(channel)
        let last = session.messages(in: channel.id).last
        return Button {
            openChannel(channel)
        } label: {
            HStack(spacing: 12) {
                if channel.type == .groupDM {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.bubble)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "person.2.fill")
                                .foregroundStyle(Theme.icon)
                        }
                } else {
                    AvatarView(user: other, diameter: 48)
                        .overlay(alignment: .bottomTrailing) {
                            PresenceDot(status: session.presenceStatus(for: other?.id))
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(dmTitle(channel))
                            .font(.system(size: 16, weight: unread ? .bold : .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer()
                        if let timestamp = last?.timestamp {
                            Text(Self.shortTime(timestamp))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    HStack {
                        Text(preview(last))
                            .font(.system(size: 14))
                            .foregroundStyle(unread ? Theme.soft : Theme.muted)
                            .lineLimit(1)
                        Spacer()
                        if unread {
                            CountBadge(count: 1, color: Theme.accent)
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableRowStyle())
        .contextMenu {
            Button(
                session.isDMPinned(channel) ? "Unpin conversation" : "Pin conversation",
                systemImage: session.isDMPinned(channel) ? "pin.slash" : "pin"
            ) {
                Task { await session.toggleDMPinned(channel) }
            }
        }
    }

    private func dmTitle(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }

    private func preview(_ message: Message?) -> String {
        guard let message else { return "Say hi" }
        if let content = message.content, !content.isEmpty {
            return content
        }
        return "Sent an attachment"
    }

    static func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct ActivityTab: View {
    var body: some View {
        MessageFeedView(feed: .mentions)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Activity")
    }
}
