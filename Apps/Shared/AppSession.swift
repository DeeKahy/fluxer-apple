import Foundation
import Observation
import FluxerKit

/// Top level app state: authentication, the API client, and the signed-in user.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case loggedOut
        case mfaPending
        case loggingIn
        case loggedIn
    }

    private(set) var phase: Phase = .loggedOut
    private(set) var currentUser: User?
    private(set) var guilds: [Guild] = []
    var lastError: String?

    private var client: APIClient
    private var mfaTicket: String?

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

    func login(email: String, password: String) async {
        phase = .loggingIn
        lastError = nil
        do {
            switch try await client.login(email: email, password: password) {
            case .success(let token):
                KeychainStore.saveToken(token)
                currentUser = try await client.currentUser()
                phase = .loggedIn
                await loadGuilds()
            case .mfaRequired(let ticket):
                mfaTicket = ticket
                phase = .mfaPending
            }
        } catch {
            lastError = Self.describe(error)
            phase = .loggedOut
        }
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
        currentUser = nil
        guilds = []
        mfaTicket = nil
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
        case APIError.httpError(let status, _):
            return "Server error (\(status))."
        case is URLError:
            return "Could not reach the server. Check your connection."
        default:
            return "Something went wrong: \(error)"
        }
    }
}
