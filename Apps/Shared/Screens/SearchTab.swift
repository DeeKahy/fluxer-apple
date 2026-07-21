import SwiftUI
import FluxerKit

struct SearchTab: View {
    @Environment(AppSession.self) private var session

    let openChannel: (Channel) -> Void

    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !query.isEmpty {
                    results
                } else {
                    Text("Search channels, conversations, and friends by name.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .padding(20)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Channels, people, guilds")
    }

    @ViewBuilder
    private var results: some View {
        let needle = query.lowercased()
        let channels = session.guilds.flatMap { guild in
            (guild.channels ?? [])
                .filter { $0.type == .guildText && ($0.name ?? "").lowercased().contains(needle) }
                .map { (guild, $0) }
        }
        let dms = session.privateChannels.filter { channel in
            (channel.recipients ?? []).contains { $0.displayName.lowercased().contains(needle) }
                || (channel.name ?? "").lowercased().contains(needle)
        }

        if !channels.isEmpty {
            SectionLabel(text: "Channels").padding(12)
            ForEach(channels, id: \.1.id) { pair in
                Button {
                    openChannel(pair.1)
                } label: {
                    HStack(spacing: 10) {
                        Text("#").foregroundStyle(Theme.faint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pair.1.name ?? "channel")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.rowText)
                            Text(pair.0.name)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(PressableRowStyle())
            }
        }
        if !dms.isEmpty {
            SectionLabel(text: "Conversations").padding(12)
            ForEach(dms) { channel in
                Button {
                    openChannel(channel)
                } label: {
                    HStack(spacing: 10) {
                        let other = (channel.recipients ?? []).first { $0.id != session.currentUser?.id }
                        AvatarView(user: other, diameter: 30)
                        Text((channel.recipients ?? []).filter { $0.id != session.currentUser?.id }
                            .map(\.displayName).joined(separator: ", "))
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.rowText)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(PressableRowStyle())
            }
        }
        if channels.isEmpty && dms.isEmpty {
            Text("Nothing matches \"\(query)\"")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .padding(20)
        }
    }
}
