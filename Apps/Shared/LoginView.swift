import SwiftUI

struct LoginView: View {
    @Environment(AppSession.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var instanceInput = ""
    @State private var showInstanceField = false
    @State private var switchingInstance = false

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

            if !isMfaStep {
                Button("Sign in with browser") {
                    Task { await session.startBrowserLogin() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                instancePicker
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: showCaptcha) {
            VStack(spacing: 16) {
                Text("Prove you're human")
                    .font(.headline)
                    .padding(.top, 20)
                CaptchaView(config: session.instanceConfig) { token in
                    Task { await session.submitCaptcha(token: token) }
                }
                .frame(minWidth: 340, minHeight: 500)
                Button("Cancel") {
                    session.cancelCaptcha()
                }
                .padding(.bottom, 16)
            }
            #if os(macOS)
            .frame(width: 420, height: 620)
            #endif
        }
    }

    @ViewBuilder
    private var instancePicker: some View {
        VStack(spacing: 6) {
            Button {
                showInstanceField.toggle()
            } label: {
                let host = session.instanceConfig.apiBase.host() ?? "fluxer.app"
                Label("Instance: \(host)", systemImage: "server.rack")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if showInstanceField {
                HStack {
                    TextField("your-instance.example.com", text: $instanceInput)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Button("Use") {
                        let input = instanceInput
                        switchingInstance = true
                        Task {
                            _ = await session.useInstance(input)
                            switchingInstance = false
                            showInstanceField = false
                        }
                    }
                    .disabled(instanceInput.trimmingCharacters(in: .whitespaces).isEmpty || switchingInstance)
                }
                .frame(maxWidth: 320)
                if session.instanceConfig != .fluxerApp {
                    Button("Back to fluxer.app") {
                        session.resetToDefaultInstance()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
        .padding(.top, 8)
    }

    private var showCaptcha: Binding<Bool> {
        Binding(
            get: { session.phase == .captchaPending },
            set: { isShown in
                if !isShown && session.phase == .captchaPending {
                    session.cancelCaptcha()
                }
            }
        )
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
