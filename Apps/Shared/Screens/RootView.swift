import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        content
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .background(Theme.bg)
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loggedOut, .mfaPending, .captchaPending:
            LoginView()
        case .emailConfirmationPending(let email):
            EmailConfirmationView(email: email)
        case .handoffPending(let code):
            HandoffView(code: code)
        case .loggingIn:
            ProgressView("Signing in")
                .controlSize(.large)
        case .loggedIn:
            MainView()
        }
    }
}
