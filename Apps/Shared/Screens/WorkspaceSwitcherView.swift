import SwiftUI
import FluxerKit

struct WorkspaceSwitcherView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @Binding var currentId: String

    @State private var joinCode = ""
    @State private var showJoinPrompt = false
    @State private var newGuildName = ""
    @State private var showCreatePrompt = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Workspaces")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(SquishButtonStyle())
                    .liquidGlassCircle()
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(session.guilds) { guild in
                            tile(guild)
                        }
                        addTile
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 40)
                }
            }
        }
        .alert("Join a guild", isPresented: $showJoinPrompt) {
            TextField("Invite code or link", text: $joinCode)
            Button("Join") {
                let code = joinCode
                joinCode = ""
                Task { _ = await session.joinGuild(code: code) }
            }
            Button("Cancel", role: .cancel) { joinCode = "" }
        }
        .alert("Create a guild", isPresented: $showCreatePrompt) {
            TextField("Guild name", text: $newGuildName)
            Button("Create") {
                let name = newGuildName
                newGuildName = ""
                Task { _ = await session.createGuild(name: name) }
            }
            Button("Cancel", role: .cancel) { newGuildName = "" }
        }
    }

    private func tile(_ guild: Guild) -> some View {
        let unread = session.hasUnread(guild)
        return Button {
            currentId = guild.id.stringValue
            dismiss()
        } label: {
            VStack(spacing: 9) {
                GuildTile(guild: guild, size: 96, radius: 22)
                    .overlay(alignment: .topTrailing) {
                        if unread {
                            CountBadge(count: 1)
                                .offset(x: 6, y: -6)
                        }
                    }
                    .overlay {
                        if currentId == guild.id.stringValue {
                            RoundedRectangle(cornerRadius: 22)
                                .strokeBorder(Theme.accent, lineWidth: 2.5)
                        }
                    }
                Text(guild.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(currentId == guild.id.stringValue ? Theme.text : Theme.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(SquishButtonStyle())
        .contextMenu {
            if guild.ownerId != session.currentUser?.id {
                Button("Leave guild", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await session.leaveGuild(guild) }
                }
            }
        }
    }

    private var addTile: some View {
        Menu {
            Button("Join with invite", systemImage: "arrow.right.circle") {
                showJoinPrompt = true
            }
            Button("Create a guild", systemImage: "plus.circle") {
                showCreatePrompt = true
            }
        } label: {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                Text("Add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
