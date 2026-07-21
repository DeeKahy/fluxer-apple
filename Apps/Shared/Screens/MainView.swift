import SwiftUI

/// Routes the signed-in experience by width: the five tab shell on
/// compact layouts, the sidebar shell everywhere else.
struct MainView: View {
    @Environment(AppSession.self) private var session
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        shell
            .overlay(alignment: .top) {
                transientErrorBanner
            }
            .animation(.easeOut(duration: 0.2), value: session.transientError)
    }

    @ViewBuilder
    private var shell: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            TabShell()
        } else {
            DesktopShell()
        }
        #else
        DesktopShell()
        #endif
    }

    /// Failures from operations without their own error surface drop in
    /// from the top for a few seconds instead of vanishing silently.
    @ViewBuilder
    private var transientErrorBanner: some View {
        if let error = session.transientError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.red)
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(error.id)
            .onTapGesture { session.transientError = nil }
        }
    }
}
