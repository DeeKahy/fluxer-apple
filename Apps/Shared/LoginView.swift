import SwiftUI

struct LoginView: View {
    @Environment(AppSession.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var mfaCode = ""

    private var isMfaStep: Bool {
        session.phase == .mfaPending
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Fluxer")
                    .font(.largeTitle.bold())
                Text(isMfaStep ? "Enter your authenticator code" : "Sign in to your account")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                if isMfaStep {
                    TextField("6 digit code", text: $mfaCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.monospacedDigit())
                        .multilineTextAlignment(.center)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        #endif
                        .onSubmit(submit)
                } else {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .onSubmit(submit)
                }
            }
            .frame(maxWidth: 320)

            if let error = session.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button(action: submit) {
                Text(isMfaStep ? "Verify" : "Sign in")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canSubmit: Bool {
        if isMfaStep {
            return mfaCode.count >= 6
        }
        return !email.isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            if isMfaStep {
                await session.submitMfaCode(mfaCode)
            } else {
                await session.login(email: email, password: password)
            }
        }
    }
}
