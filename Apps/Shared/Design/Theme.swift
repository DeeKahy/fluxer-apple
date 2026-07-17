import SwiftUI
import FluxerKit

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Design tokens for the ink-dark look: near-black layered surfaces,
/// indigo accent, hairline separators, and a warm name palette.
enum Theme {
    static let bg = Color(hex: 0x0B0B10)
    static let surface = Color(hex: 0x15151D)
    static let field = Color(hex: 0x16161D)
    static let bubble = Color(hex: 0x1A1A22)
    static let sheet = Color(hex: 0x1C1C24)
    static let heroTile = Color(hex: 0x20202A)

    static let text = Color(hex: 0xECECF1)
    static let messageText = Color(hex: 0xE4E4EC)
    static let rowText = Color(hex: 0xD6D6DE)
    static let soft = Color(hex: 0xC8C8D2)
    static let icon = Color(hex: 0xB6B6C2)
    static let secondary = Color(hex: 0x8A8A96)
    static let muted = Color(hex: 0x6C6C78)
    static let faint = Color(hex: 0x4A4A55)

    static let accent = Color(hex: 0x5B6CFF)
    static let accentSoft = Color(hex: 0x8B96FF)
    static let green = Color(hex: 0x3BA55D)
    static let red = Color(hex: 0xED4245)
    static let hairline = Color.white.opacity(0.07)

    // Desktop comp surfaces
    static let railBg = Color(hex: 0x08080B)
    static let sidebarBg = Color(hex: 0x111118)
    static let sidebarField = Color(hex: 0x1C1C26)
    static let sectionMuted = Color(hex: 0x5C5C68)
    static let deskBg = Color(hex: 0x0D0D12)
    static let panelBg = Color(hex: 0x101017)
    static let selfBarBg = Color(hex: 0x0C0C11)
    static let deskTile = Color(hex: 0x20202A)
    static let sendIdle = Color(hex: 0x2A2A34)
    static let idleYellow = Color(hex: 0xFAA61A)
    static let offlineGray = Color(hex: 0x747F8D)

    /// Presence status to dot color, comp palette.
    static func presenceColor(_ status: String?) -> Color {
        switch status {
        case "online": return green
        case "idle": return idleYellow
        case "dnd": return red
        default: return offlineGray
        }
    }

    /// Stable per-user name colors, like the comp's colored usernames.
    static let namePalette: [Color] = [
        Color(hex: 0x8B96FF), Color(hex: 0xFA709A), Color(hex: 0x3BA55D),
        Color(hex: 0xFFD93D), Color(hex: 0xFF6B6B), Color(hex: 0x8B5CF6),
        Color(hex: 0x4FC3F7), Color(hex: 0xFEB47B),
    ]

    static func nameColor(for id: Snowflake?) -> Color {
        guard let id else { return text }
        return namePalette[Int(id.rawValue % UInt64(namePalette.count))]
    }

    /// Workspace tile backgrounds for guilds without icons.
    static let tilePalette: [Color] = [
        Color(hex: 0x5B6CFF), Color(hex: 0x8B5CF6), Color(hex: 0x3BA55D),
        Color(hex: 0xE8590C), Color(hex: 0x0EA5E9), Color(hex: 0xDB2777),
    ]

    static func tileColor(for id: Snowflake) -> Color {
        tilePalette[Int(id.rawValue % UInt64(tilePalette.count))]
    }
}

/// 12pt uppercase tracked section label from the comp.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(Theme.muted)
    }
}

/// Red count pill with the dark keyline ring.
struct CountBadge: View {
    let count: Int
    var color: Color = Theme.red

    var body: some View {
        Text("\(min(count, 99))")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 19, minHeight: 19)
            .background(color, in: Capsule())
    }
}

/// 34pt circular dark icon button from the comp headers.
struct CircleIconButton: View {
    let systemImage: String
    var size: CGFloat = 34
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .background(Theme.bubble, in: Circle())
        }
        .buttonStyle(SquishButtonStyle())
    }
}

/// Guild tile: icon image or colored initial block.
struct GuildTile: View {
    let guild: Guild
    var size: CGFloat = 34
    var radius: CGFloat = 11

    var body: some View {
        RemoteImage(url: guild.iconURL(size: Int(size * 2))) {
            RoundedRectangle(cornerRadius: radius)
                .fill(Theme.tileColor(for: guild.id))
                .overlay {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    private var initials: String {
        let words = guild.name.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
