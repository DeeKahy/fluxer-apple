import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Cross-version Liquid Glass helpers. On iOS 26 and macOS 26 these use the
/// real glassEffect APIs; older systems fall back to system materials so the
/// deployment targets can stay at iOS 17 / macOS 14.
extension View {
    /// Glass capsule, the default Liquid Glass shape.
    @ViewBuilder nonisolated
    func liquidGlass(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Glass clipped to a rounded rectangle.
    @ViewBuilder nonisolated
    func liquidGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Tinted glass in a rounded rectangle, for accent surfaces like the
    /// voice pill and send key.
    @ViewBuilder nonisolated
    func liquidGlass(tint: Color, cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(
                interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        } else {
            background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Glass circle for round icon buttons.
    @ViewBuilder nonisolated
    func liquidGlassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let tint {
                glassEffect(
                    interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: Circle()
                )
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: Circle())
            }
        } else if let tint {
            background(tint.opacity(0.85), in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Groups nearby glass shapes so they can merge and morph together.
/// A plain Group on systems without Liquid Glass.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

#if os(macOS)
/// Behind-window vibrancy, the translucent sidebar look native macOS apps
/// have. SwiftUI's Material only blurs in-window content, so this wraps
/// NSVisualEffectView directly.
struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
#endif
