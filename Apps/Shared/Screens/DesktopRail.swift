import SwiftUI
import FluxerKit

struct DesktopRail: View {
    @Environment(AppSession.self) private var session

    let currentGuildId: Snowflake?
    let onSelect: (Guild) -> Void
    let onJoin: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(session.guilds) { guild in
                        RailButton(
                            selected: currentGuildId == guild.id,
                            badge: mentionCount(guild),
                            action: { onSelect(guild) }
                        ) { active in
                            GuildTile(guild: guild, size: 46, radius: active ? 16 : 23)
                        }
                        .contextMenu {
                            if guild.ownerId != session.currentUser?.id {
                                Button("Leave guild", role: .destructive) {
                                    Task { await session.leaveGuild(guild) }
                                }
                            }
                        }
                    }
                    Menu {
                        Button("Join with invite", systemImage: "arrow.right.circle", action: onJoin)
                        Button("Create a guild", systemImage: "plus.circle", action: onCreate)
                    } label: {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Theme.surface)
                            .frame(width: 46, height: 46)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.green)
                            }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 46, height: 46)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 74)
        .frame(maxHeight: .infinity)
        .background {
            #if os(macOS)
            BehindWindowBlur(material: .underWindowBackground)
                .overlay(Theme.railBg.opacity(0.6))
                .ignoresSafeArea()
            #else
            Theme.railBg
            #endif
        }
    }

    private func mentionCount(_ guild: Guild) -> Int {
        (guild.channels ?? []).reduce(0) { $0 + (session.mentionCounts[$1.id] ?? 0) }
    }
}

/// One rail tile: white selection bar on the left edge, squircle morph on
/// hover or selection, badge riding the bottom right corner.
private struct RailButton<Content: View>: View {
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    content(selected || hovered)
                        .overlay {
                            // Comp's white keyline around the active tile.
                            if selected {
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                                    .padding(-2)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if badge > 0 {
                                CountBadge(count: badge)
                                    .background {
                                        Capsule().fill(Theme.railBg).padding(-3)
                                    }
                                    .offset(x: 5, y: 3)
                            }
                        }
                }
                .buttonStyle(SquishButtonStyle())
                .onHover { hovered = $0 }
                Spacer(minLength: 0)
            }
            UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                .fill(.white)
                .frame(width: 4, height: selected ? 40 : 0)
        }
        .frame(width: 74)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}
