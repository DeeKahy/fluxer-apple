import SwiftUI
import FluxerKit

struct DesktopSearchResults: View {
    @Environment(AppSession.self) private var session

    let query: String
    let guild: Guild?
    let onOpenChannel: (Channel) -> Void
    let onOpenProfile: (User) -> Void

    private var normalized: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var matchedChannels: [Channel] {
        let channels = (guild?.channels ?? []).filter {
            $0.type == .guildText || $0.type == .guildVoice
        }
        return channels.filter { ($0.name ?? "").lowercased().contains(normalized) }
    }

    private var matchedDMs: [Channel] {
        session.privateChannels.filter { channel in
            let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
            let name = channel.name ?? others.map(\.displayName).joined(separator: ", ")
            return name.lowercased().contains(normalized)
        }
    }

    private var matchedPeople: [User] {
        var seen: Set<Snowflake> = []
        var result: [User] = []
        let candidates = session.knownUsers.values.sorted { $0.displayName < $1.displayName }
        for user in candidates {
            guard !seen.contains(user.id),
                  user.displayName.lowercased().contains(normalized)
                    || (user.username ?? "").lowercased().contains(normalized)
            else { continue }
            seen.insert(user.id)
            result.append(user)
            if result.count >= 8 { break }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                (Text("Results for ").foregroundStyle(Theme.secondary)
                    + Text("\"\(query)\"").bold().foregroundStyle(Theme.text))
                    .font(.system(size: 15))
                    .padding(.bottom, 18)

                if !matchedPeople.isEmpty {
                    resultHeader("People")
                    ForEach(matchedPeople) { user in
                        Button {
                            onOpenProfile(user)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(user: user, diameter: 38)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    if let username = user.username {
                                        Text(username)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer()
                            }
                            .padding(8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(DeskRowStyle())
                    }
                }

                if !matchedChannels.isEmpty {
                    resultHeader("Channels")
                    ForEach(matchedChannels) { channel in
                        channelResult(channel, glyph: channel.type == .guildVoice ? "speaker.wave.2" : nil)
                    }
                }

                if !matchedDMs.isEmpty {
                    resultHeader("Direct messages")
                    ForEach(matchedDMs) { channel in
                        channelResult(channel, glyph: "bubble.left")
                    }
                }

                if matchedPeople.isEmpty && matchedChannels.isEmpty && matchedDMs.isEmpty {
                    Text("No results found.")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.deskBg)
    }

    private func resultHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.sectionMuted)
            .padding(.top, 14)
            .padding(.bottom, 10)
    }

    private func channelResult(_ channel: Channel, glyph: String?) -> some View {
        Button {
            onOpenChannel(channel)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.deskTile)
                    .frame(width: 30, height: 30)
                    .overlay {
                        if let glyph {
                            Image(systemName: glyph)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accentSoft)
                        } else {
                            Text("#").foregroundStyle(Theme.accentSoft)
                        }
                    }
                Text(channelResultName(channel))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(DeskRowStyle())
    }

    private func channelResultName(_ channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        let others = (channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
        return others.map(\.displayName).joined(separator: ", ")
    }
}
