import SwiftUI

/// Browser login pairing screen. Shows the handoff code, opens the web
/// login, and waits while the session polls for approval.
struct HandoffView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL

    let code: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "safari")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Sign in with your browser")
                    .font(.title.bold())
                Text("Sign in at web.fluxer.app in your browser, then enter this code when it asks for one.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Text(code)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .kerning(2)
                .textSelection(.enabled)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Button {
                openURL(AppSession.browserLoginURL)
            } label: {
                Label("Open web.fluxer.app", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            ProgressView()

            Text("The code expires after 5 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Cancel", role: .cancel) {
                session.cancelBrowserLogin()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
