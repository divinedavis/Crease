import Foundation
import Supabase
import SwiftUI

/// Supabase client + auth state.
///
/// Sign-in is Apple or Google. Nothing here sends the customer to their inbox:
/// no confirmation link, and no emailed code either. Both put a mail app
/// between someone and their first order, and a meaningful share of them do
/// not come back — the emailed code is only marginally better than the
/// confirmation link it replaced, because it is still a round trip through
/// another app.
///
/// The consequence is that both providers must actually work. There is no
/// email fallback to hide behind if one of them is misconfigured.
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
        let url = URL(string: "https://\(host)")!

        #if DEBUG
        // A signed-out UI test gets a client that stores its session nowhere.
        //
        // Reaching signed-out by calling signOut() looked equivalent and was
        // not: /logout revokes the session on the server, and the session in
        // question is the single one scripts/ios-test.sh mints for the whole
        // run. Every signed-in test scheduled after the sign-out test then
        // launched to the sign-in screen with "Auth session missing", which
        // reads as a broken feature rather than a poisoned fixture.
        if ProcessInfo.processInfo.arguments.contains("-uiTestSignedOut") {
            client = SupabaseClient(
                supabaseURL: url,
                supabaseKey: key,
                options: .init(auth: .init(storage: EphemeralAuthStorage()))
            )
            Task { await restore() }
            return
        }
        #endif

        client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        Task { await restore() }
    }

    var userId: UUID? {
        if case let .signedIn(id) = state { return id }
        return nil
    }

    private func restore() async {
        #if DEBUG
        // Supabase persists the session in the keychain, which outlives an app
        // reinstall on the simulator, so the signed-in tests would otherwise
        // leak a session into the sign-out test and it would assert against
        // the wrong screen. Nothing to clear here though: this client was
        // built on storage that starts empty and dies with the process (see
        // init), and signing out would revoke the shared test session.
        if ProcessInfo.processInfo.arguments.contains("-uiTestSignedOut") {
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

    /// Google, via the system browser sheet.
    ///
    /// Uses the hosted OAuth flow rather than the native Google SDK: it needs
    /// only a web client configured in Supabase, adds no third-party
    /// dependency to the app, and the account picker is the one people already
    /// recognise. The redirect scheme must match the one registered in
    /// Info.plist or the sheet opens and never returns.
    func signInWithGoogle() async {
        do {
            try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: URL(string: "crease://auth-callback")
            )
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

#if DEBUG
/// Session storage that keeps nothing past the process.
///
/// Used only by the signed-out UI test launch, which needs an app that starts
/// with no session and leaves the real one — server-side and in the simulator
/// keychain — exactly as it found it.
private final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }
}
#endif
