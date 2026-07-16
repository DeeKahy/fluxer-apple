import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.phase {
        case .loggedOut, .mfaPending, .captchaPending:
            LoginView()
        case .loggingIn:
            ProgressView("Signing in")
                .controlSize(.large)
        case .loggedIn:
            HomeView()
        }
    }
}
