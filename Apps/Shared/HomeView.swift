import SwiftUI
import FluxerKit

/// Placeholder home screen: proves login worked by showing the account
/// and the guild list. Channel and message views come next.
struct HomeView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            List {
                if let user = session.currentUser {
                    Section("Account") {
                        LabeledContent("Signed in as", value: user.displayName)
                        LabeledContent("Username", value: user.username)
                    }
                }
                Section("Guilds") {
                    if session.guilds.isEmpty {
                        Text("No guilds yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.guilds) { guild in
                        VStack(alignment: .leading) {
                            Text(guild.name)
                            if let description = guild.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fluxer")
            .toolbar {
                Button("Log out", role: .destructive) {
                    Task { await session.logout() }
                }
            }
            .refreshable {
                await session.loadGuilds()
            }
        }
    }
}
