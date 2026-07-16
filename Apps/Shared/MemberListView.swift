import SwiftUI
import FluxerKit

/// Small colored dot showing a user's presence.
struct PresenceDot: View {
    let status: String?

    private var color: Color {
        switch status {
        case "online": return .green
        case "idle": return .yellow
        case "dnd": return .red
        default: return .gray.opacity(0.5)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                Circle().strokeBorder(.background, lineWidth: 1.5)
            }
    }
}

struct MemberListView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let guildId: Snowflake

    @State private var filter = ""

    private var guild: Guild? {
        session.guilds.first { $0.id == guildId }
    }

    private var members: [GuildMember] {
        let all = session.guildMembers[guildId] ?? []
        guard !filter.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            List {
                if session.guildMembers[guildId] == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                    HStack(spacing: 10) {
                        AvatarView(user: member.user, diameter: 32)
                            .overlay(alignment: .bottomTrailing) {
                                PresenceDot(status: session.presenceStatus(for: member.user?.id))
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.displayName)
                            if let username = member.user?.username, username != member.displayName {
                                Text(username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contextMenu {
                        if let userId = member.user?.id, userId != session.currentUser?.id {
                            Button("Message", systemImage: "bubble.left") {
                                Task {
                                    if let dm = await session.openDM(with: userId) {
                                        dismiss()
                                        session.channelJump = dm
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Filter members")
            .navigationTitle(guild.map { "Members of \($0.name)" } ?? "Members")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task {
                if let guild {
                    await session.loadMembers(for: guild)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }
}
