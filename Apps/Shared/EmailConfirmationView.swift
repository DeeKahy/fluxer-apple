import SwiftUI

/// Shown while Fluxer waits for the person to click the new-device
/// confirmation link it sent by email. The session polls in the
/// background and moves on automatically once the link is clicked.
struct EmailConfirmationView: View {
    @Environment(AppSession.self) private var session

    let email: String

    @State private var resent = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Check your email")
                    .font(.title.bold())
                Text("This device hasn't signed in before. Fluxer sent a confirmation link to \(email). Click it and this screen will continue on its own.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            ProgressView()

            VStack(spacing: 12) {
                Button(resent ? "Email sent again" : "Resend email") {
                    resent = true
                    Task { await session.resendConfirmationEmail() }
                }
                .disabled(resent)

                Button("Cancel", role: .cancel) {
                    session.cancelEmailConfirmation()
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
