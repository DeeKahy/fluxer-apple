import SwiftUI
import FluxerKit

/// Round avatar image with an initial as placeholder and fallback.
struct AvatarView: View {
    let user: User?
    var diameter: CGFloat = 36

    var body: some View {
        AsyncImage(url: user?.avatarURL(size: Int(diameter * 2))) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            initialCircle
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private var initialCircle: some View {
        Circle()
            .fill(.tint.opacity(0.25))
            .overlay {
                Text(String((user?.displayName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: diameter * 0.45, weight: .semibold))
                    .foregroundStyle(.tint)
            }
    }
}
