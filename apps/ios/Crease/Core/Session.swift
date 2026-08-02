import Foundation
import Supabase
import SwiftUI

/// Supabase client + auth state.
///
/// Sign-in is Apple, Google, or a one-time email code. There is deliberately no
/// "check your inbox to confirm" step anywhere — a verification email between a
/// customer and their first order is a step where people simply leave.
@MainActor
final class Session: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(userId: UUID)
    }

    @Published private(set) var state: State = .loading
    @Published var errorMessage: String?

    let client: SupabaseClient

    init() {
        let info = Bundle.main.infoDictionary
        let host = info?["SUPABASE_HOST"] as? String ?? ""
        let key = info?["SUPABASE_ANON_KEY"] as? String ?? ""
        client = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: key
        )
        Task { await restore() }
    }

    var userId: UUID? {
        if case let .signedIn(id) = state { return id }
        return nil
    }

    private func restore() async {
        #if DEBUG
        // Supabase persists the session in the keychain, which outlives an app
        // reinstall on the simulator. Without an explicit reset the signed-in
        // tests leak a session into the sign-out test, which then quietly
        // asserts against the wrong screen — and passes or fails for reasons
        // that have nothing to do with the code under test.
        if ProcessInfo.processInfo.arguments.contains("-uiTestSignedOut") {
            try? await client.auth.signOut()
            state = .signedOut
            return
        }

        // UI tests cannot complete Apple sign-in in a simulator, and the email
        // code path needs SMTP. Both would make the signed-in screens
        // untestable, so DEBUG builds accept a real session minted server-side
        // and passed in as a launch argument. Compiled out of Release, so this
        // cannot become a way into a shipped build.
        if let token = launchArgument("-uiTestAccessToken"),
           let refresh = launchArgument("-uiTestRefreshToken") {
            do {
                let session = try await client.auth.setSession(
                    accessToken: token, refreshToken: refresh
                )
                state = .signedIn(userId: session.user.id)
                return
            } catch {
                state = .signedOut
                errorMessage = "Test session injection failed: \(error.localizedDescription)"
                return
            }
        }
        #endif

        do {
            let session = try await client.auth.session
            state = .signedIn(userId: session.user.id)
        } catch {
            state = .signedOut
        }
    }

    #if DEBUG
    private func launchArgument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    #endif

    /// Sends a 6-digit code. Not a magic link: a link bounces the customer out
    /// to a mail app and often to a different browser, which loses the session
    /// and the order they were mid-way through creating.
    func sendEmailCode(to email: String) async -> Bool {
        do {
            try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func verifyEmailCode(email: String, code: String) async {
        do {
            try await client.auth.verifyOTP(email: email, token: code, type: .email)
            await restore()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signInWithApple(idToken: String, nonce: String) async {
        do {
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
            await restore()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut
    }

    private func friendly(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.contains("Invalid login") || raw.contains("expired") {
            return "That code didn't work. Request a new one."
        }
        if raw.contains("offline") || raw.contains("network") {
            return "You appear to be offline."
        }
        // Anything else is shown verbatim rather than softened. A provider
        // misconfiguration reads as an ordinary sign-in failure otherwise, and
        // the one detail that identifies it is the part being thrown away.
        return raw
    }
}
