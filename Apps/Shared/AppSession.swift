import Foundation
import Observation
import FluxerKit

/// Top level app state: authentication, the API client, and the signed-in user.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case loggedOut
        case captchaPending
        case mfaPending
        case emailConfirmationPending(email: String)
        case handoffPending(code: String)
        case loggingIn
        case loggedIn
    }

    private(set) var phase: Phase = .loggedOut
    private(set) var currentUser: User?
    private(set) var guilds: [Guild] = []
    var lastError: String?

    private var client: APIClient
    private var mfaTicket: String?
    private var pendingLogin: (email: String, password: String)?
    private var ipAuthTicket: String?
    private var ipAuthPollTask: Task<Void, Never>?
    private var handoffCode: String?
    private var handoffPollTask: Task<Void, Never>?

    /// Where the person completes a browser login for this instance.
    static let browserLoginURL = URL(string: "https://web.fluxer.app/login?handoff=1")!

    init() {
        self.client = APIClient()
        if let token = KeychainStore.loadToken() {
            Task { await self.restore(token: token) }
        }
    }

    private func restore(token: String) async {
        phase = .loggingIn
        await client.setCredential(.user(token: token))
        do {
            currentUser = try await client.currentUser()
            phase = .loggedIn
            await loadGuilds()
        } catch {
            KeychainStore.deleteToken()
            await client.setCredential(nil)
            phase = .loggedOut
        }
    }

    func login(email: String, password: String, captcha: CaptchaSolution? = nil) async {
        phase = .loggingIn
        lastError = nil
        do {
            switch try await client.login(email: email, password: password, captcha: captcha) {
            case .success(let token):
                KeychainStore.saveToken(token)
                pendingLogin = nil
                currentUser = try await client.currentUser()
                phase = .loggedIn
                await loadGuilds()
            case .mfaRequired(let ticket, let totp, _):
                pendingLogin = nil
                if totp {
                    mfaTicket = ticket
                    phase = .mfaPending
                } else {
                    lastError = "This account uses a passkey. Use \"Sign in with browser\" below."
                    phase = .loggedOut
                }
            case .ipAuthorizationRequired(let ticket, let email):
                pendingLogin = nil
                ipAuthTicket = ticket
                phase = .emailConfirmationPending(email: email)
                startIpAuthPolling()
            }
        } catch APIError.captchaRequired {
            pendingLogin = (email, password)
            phase = .captchaPending
        } catch APIError.invalidCaptcha {
            pendingLogin = (email, password)
            lastError = "Captcha check failed, try again."
            phase = .captchaPending
        } catch {
            lastError = Self.describe(error)
            phase = .loggedOut
        }
    }

    func submitCaptcha(token: String) async {
        guard let pending = pendingLogin else {
            phase = .loggedOut
            return
        }
        await login(
            email: pending.email,
            password: pending.password,
            captcha: CaptchaSolution(token: token)
        )
    }

    func cancelCaptcha() {
        pendingLogin = nil
        phase = .loggedOut
    }

    /// Polls until the person clicks the confirmation link Fluxer emailed them.
    private func startIpAuthPolling() {
        ipAuthPollTask?.cancel()
        ipAuthPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let ticket = ipAuthTicket, case .emailConfirmationPending = phase else { return }
                guard let status = try? await client.pollIpAuthorization(ticket: ticket) else { continue }
                if status.completed {
                    ipAuthTicket = nil
                    if let token = status.token {
                        KeychainStore.saveToken(token)
                        phase = .loggingIn
                        currentUser = try? await client.currentUser()
                        phase = currentUser != nil ? .loggedIn : .loggedOut
                        if currentUser != nil {
                            await loadGuilds()
                        }
                    } else {
                        lastError = "Device confirmed, sign in again."
                        phase = .loggedOut
                    }
                    return
                }
            }
        }
    }

    /// Starts a browser login: get a pairing code, show it, and poll for
    /// approval while the person signs in on the web and enters the code.
    func startBrowserLogin() async {
        lastError = nil
        do {
            let initiation = try await client.initiateHandoff()
            handoffCode = initiation.code
            phase = .handoffPending(code: initiation.code)
            startHandoffPolling()
        } catch {
            lastError = Self.describe(error)
            phase = .loggedOut
        }
    }

    private func startHandoffPolling() {
        handoffPollTask?.cancel()
        handoffPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let code = handoffCode, case .handoffPending = phase else { return }
                guard let status = try? await client.pollHandoff(code: code) else { continue }
                if status.isCompleted, let token = status.token {
                    handoffCode = nil
                    KeychainStore.saveToken(token)
                    phase = .loggingIn
                    currentUser = try? await client.currentUser()
                    phase = currentUser != nil ? .loggedIn : .loggedOut
                    if currentUser != nil {
                        await loadGuilds()
                    }
                    return
                }
                if status.isExpired {
                    handoffCode = nil
                    lastError = "The code expired, try again."
                    phase = .loggedOut
                    return
                }
            }
        }
    }

    func cancelBrowserLogin() {
        handoffPollTask?.cancel()
        handoffPollTask = nil
        if let code = handoffCode {
            Task { try? await client.cancelHandoff(code: code) }
        }
        handoffCode = nil
        phase = .loggedOut
    }

    func resendConfirmationEmail() async {
        guard let ticket = ipAuthTicket else { return }
        try? await client.resendIpAuthorization(ticket: ticket)
    }

    func cancelEmailConfirmation() {
        ipAuthPollTask?.cancel()
        ipAuthPollTask = nil
        ipAuthTicket = nil
        phase = .loggedOut
    }

    func submitMfaCode(_ code: String) async {
        guard let ticket = mfaTicket else { return }
        phase = .loggingIn
        lastError = nil
        do {
            let token = try await client.loginMfaTotp(code: code, ticket: ticket)
            KeychainStore.saveToken(token)
            mfaTicket = nil
            currentUser = try await client.currentUser()
            phase = .loggedIn
            await loadGuilds()
        } catch {
            lastError = Self.describe(error)
            phase = .mfaPending
        }
    }

    func logout() async {
        try? await client.logout()
        KeychainStore.deleteToken()
        ipAuthPollTask?.cancel()
        ipAuthPollTask = nil
        ipAuthTicket = nil
        currentUser = nil
        guilds = []
        mfaTicket = nil
        pendingLogin = nil
        phase = .loggedOut
    }

    func loadGuilds() async {
        do {
            guilds = try await client.myGuilds()
        } catch {
            lastError = Self.describe(error)
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case APIError.unauthorized:
            return "Wrong email or password."
        case APIError.rateLimited:
            return "Too many attempts, wait a moment and try again."
        case APIError.httpError(let status, _, let message):
            return message ?? "Server error (\(status))."
        case is URLError:
            return "Could not reach the server. Check your connection."
        default:
            return "Something went wrong: \(error)"
        }
    }
}
