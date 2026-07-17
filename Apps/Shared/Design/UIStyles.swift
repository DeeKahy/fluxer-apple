import SwiftUI

/// Full-width tappable row with hover highlight and a press morph.
/// The whole surface is the hit target, not just the label.
struct RowTap<Label: View>: View {
    var isSelected = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PressableRowStyle(hovering: hovering, isSelected: isSelected))
        .onHover { hovering = $0 }
    }
}

/// Rounded row background: accent tint when selected, soft fill on hover,
/// deeper fill plus a slight shrink while pressed.
struct PressableRowStyle: ButtonStyle {
    var hovering = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor(pressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if pressed {
            return Color.accentColor.opacity(0.22)
        }
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        if hovering {
            return Color.primary.opacity(0.07)
        }
        return .clear
    }
}

/// Springy shrink for small controls like reaction pills and icon buttons.
struct SquishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Expands a small control's hit area and adds hover and press feedback,
/// for avatars and other tap targets that are visually compact.
struct TapTarget: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(
                Circle().fill(hovering ? Color.primary.opacity(0.08) : .clear)
            )
            .padding(-4)
            .contentShape(Circle().inset(by: -6))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func tapTarget() -> some View {
        modifier(TapTarget())
    }

    /// Tight insets so RowTap pills span the list row.
    func rowTapInsets() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
    }
}
