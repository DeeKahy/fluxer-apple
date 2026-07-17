import SwiftUI

/// Routes the signed-in experience by width: the five tab shell on
/// compact layouts, the sidebar shell everywhere else.
struct MainView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
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
}
