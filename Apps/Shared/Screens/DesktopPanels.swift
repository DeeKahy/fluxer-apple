import SwiftUI
import FluxerKit

struct DesktopMembersPanel: View {
    @Environment(AppSession.self) private var session

    let guildId: Snowflake
    let onClose: () -> Void
    let onOpenProfile: (User) -> Void

    private var guild: Guild? {
        session.guilds.first { $0.id == guildId }
    }

    private var members: [GuildMember] {
        session.guildMembers[guildId] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Members · \(members.count)")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Spacer()
                PanelCloseButton(action: onClose)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if session.guildMembers[guildId] == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                        Button {
                            if let user = member.user { onOpenProfile(user) }
                        } label: {
                            HStack(spacing: 11) {
                                AvatarView(user: member.user, diameter: 36)
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(Theme.presenceColor(session.presenceStatus(for: member.user?.id)))
                                            .frame(width: 11, height: 11)
                                            .overlay { Circle().strokeBorder(Theme.panelBg, lineWidth: 2) }
                                            .offset(x: 2, y: 2)
                                    }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(roleColor: guild?.roleColorValue(for: member.roles)) ?? Theme.text)
                                        .lineLimit(1)
                                    if let username = member.user?.username, username != member.displayName {
                                        Text(username)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.muted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(DeskRowStyle())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 300)
        .background(Theme.panelBg)
        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
        .task {
            if let guild {
                await session.loadMembers(for: guild)
            }
        }
    }
}

struct DesktopProfilePanel: View {
    @Environment(AppSession.self) private var session

    let user: User
    let onClose: () -> Void
    let onOpenDM: (Channel) -> Void

    @State private var profile: APIClient.UserProfile?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(Theme.tileColor(for: user.id))
                        .frame(height: 110)
                    PanelCloseButton(dark: true, action: onClose)
                        .padding(12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    AvatarView(user: user, diameter: 72)
                        .overlay {
                            Circle().strokeBorder(Theme.panelBg, lineWidth: 5)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .fill(Theme.presenceColor(session.presenceStatus(for: user.id)))
                                .frame(width: 17, height: 17)
                                .overlay { Circle().strokeBorder(Theme.panelBg, lineWidth: 3) }
                        }
                        .offset(y: -36)
                        .padding(.bottom, -36)
                    Text(user.displayName)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .padding(.top, 10)
                    if let username = user.username {
                        Text("@\(username)")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.presenceColor(session.presenceStatus(for: user.id)))
                            .frame(width: 8, height: 8)
                        Text(presenceLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.soft)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                    .padding(.top, 10)
                    if user.id != session.currentUser?.id {
                        Button {
                            Task {
                                if let dm = await session.openDM(with: user.id) {
                                    onOpenDM(dm)
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.system(size: 13))
                                Text("Message")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(SquishButtonStyle())
                        .padding(.top, 16)
                    }
                    if let pronouns = profile?.pronouns, !pronouns.isEmpty {
                        panelLabel("Pronouns")
                        panelCard { Text(pronouns) }
                    }
                    if let bio = profile?.bio, !bio.isEmpty {
                        panelLabel("About")
                        panelCard { Text(bio) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 320)
        .background(Theme.panelBg)
        .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
        .task(id: user.id) {
            profile = await session.profile(of: user.id)
        }
    }

    private var presenceLabel: String {
        switch session.presenceStatus(for: user.id) {
        case "online": return "Active now"
        case "idle": return "Away"
        case "dnd": return "Do not disturb"
        default: return "Offline"
        }
    }

    private func panelLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.sectionMuted)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func panelCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .font(.system(size: 14))
            .foregroundStyle(Theme.soft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
