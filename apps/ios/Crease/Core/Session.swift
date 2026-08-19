import Foundation
import OSLog
import Supabase
import SwiftUI

private let log = Logger(subsystem: "com.divinedavis.crease", category: "auth")

/// Supabase client + auth state.
///
/// Sign-in is Apple, Google, or email and password. Nothing here sends the
/// customer to their inbox: no confirmation link, and no emailed code either.
/// Both put a mail app between someone and their first order, and a meaningful
/// share of them do not come back — the emailed code is only marginally better
/// than the confirmation link it replaced, because it is still a round trip
/// through another app.
///
/// Email carries a password instead, and the Supabase project auto-confirms, so
/// an account created here is usable the moment it exists. It is also the
/// fallback the screen used to lack: with only the two providers, one of them
/// being misconfigured was a locked door with nothing behind it.
/// Why an account could not be deleted, in terms the customer can act on.
enum DeleteAccountError: LocalizedError {
    /// A shop's staff account: its orders, payouts and colleagues belong to the
    /// business, so removing it is the owner's call, not a self-service one.
    case staffAccount
    case failed

    var errorDescription: String? {
        switch self {
        case .staffAccount:
            return "This account is linked to a shop. Ask the shop owner to remove it."
        case .failed:
            return "Something went wrong deleting your account. Please try again."
        }
    }
}

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

        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            // Pin the session to this device: the SDK's default keychain
            // accessibility can let the token migrate to another device via an
            // encrypted backup restore.
            options: .init(auth: .init(storage: KeychainAuthStorage()))
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

    /// Email and password.
    ///
    /// The third door, for the customer who has neither an Apple ID they
    /// actually use nor a Google account — and the fallback the screen used to
    /// lack entirely, where a misconfigured provider was a locked door.
    ///
    /// It still sends nobody to their inbox: the Supabase project auto-confirms
    /// addresses, so creating an account returns a session immediately and the
    /// first order is one screen away rather than one mail round trip away.
    func signInWithEmail(email: String, password: String) async {
        errorMessage = nil
        do {
            let session = try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            // Set the state from the session in hand rather than re-reading it
            // through restore(), which in DEBUG is overridden by the UI-test
            // launch arguments and would drop a real sign-in on the floor.
            state = .signedIn(userId: session.user.id)
        } catch {
            errorMessage = friendlyEmailSignIn(error)
        }
    }

    /// Creates the account and signs straight in.
    func signUpWithEmail(email: String, password: String, fullName: String) async {
        errorMessage = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let response = try await client.auth.signUp(
                email: address,
                password: password,
                // handle_new_user() copies this into profiles.full_name, so the
                // name lands with the row the trigger inserts instead of in a
                // second write that a dropped connection could lose.
                data: ["full_name": .string(name)]
            )
            if let session = response.session {
                state = .signedIn(userId: session.user.id)
                return
            }
            // A user without a session means the project stopped auto-confirming.
            // Try the credentials we were just given rather than leaving someone
            // on a sheet that looks like it worked; if confirmation really is
            // required, signInWithEmail says so in words they can act on.
            await signInWithEmail(email: address, password: password)
        } catch {
            errorMessage = friendlyEmailSignUp(error)
        }
    }

    /// Wrong-password and no-such-account collapse into one message on purpose:
    /// telling them apart tells anyone with a list of addresses which ones have
    /// accounts here. Everything else is only surfaced when it is something the
    /// customer can actually do something about.
    private func friendlyEmailSignIn(_ error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("not confirmed") {
            return "This address needs confirming before you can sign in. Contact support and we'll sort it out."
        }
        if raw.contains("rate limit") || raw.contains("too many") {
            return "Too many attempts. Wait a minute and try again."
        }
        if raw.contains("offline") || raw.contains("network") || raw.contains("connection") {
            return "You appear to be offline."
        }
        log.error("email sign-in failed: \(raw)")
        return "Incorrect email or password."
    }

    private func friendlyEmailSignUp(_ error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("already") || raw.contains("registered") || raw.contains("exists") {
            return "An account with that email already exists. Sign in instead."
        }
        if raw.contains("weak") || raw.contains("easy to guess") || raw.contains("breach") || raw.contains("pwned") {
            return "That password has turned up in a known breach. Please pick another."
        }
        if raw.contains("password") && (raw.contains("short") || raw.contains("least")) {
            return "Use a password of at least 6 characters."
        }
        if raw.contains("email") && raw.contains("invalid") {
            return "That email address isn't accepted. Try another."
        }
        if raw.contains("rate limit") || raw.contains("too many") {
            return "Too many attempts. Wait a minute and try again."
        }
        if raw.contains("offline") || raw.contains("network") || raw.contains("connection") {
            return "You appear to be offline."
        }
        log.error("email sign-up failed: \(raw)")
        return "Something went wrong creating your account. Please try again."
    }

    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut
    }

    /// Erase the account and everything attached to it.
    ///
    /// The work happens in one `delete_account()` call rather than a series of
    /// client-side deletes: the rows have to go in foreign-key order (payouts,
    /// orders and everything cascading off them, addresses, profile, then the
    /// auth user), and a phone that loses signal halfway through that sequence
    /// would leave an account that is half gone and cannot be finished.
    ///
    /// Throws `DeleteAccountError` so the caller can tell the one case worth
    /// explaining — a shop's staff account, which belongs to the business —
    /// apart from everything else, which gets the usual generic message.
    func deleteAccount() async throws {
        do {
            try await client.rpc("delete_account").execute()
        } catch {
            let raw = error.localizedDescription
            if raw.contains("staff accounts must be removed") {
                throw DeleteAccountError.staffAccount
            }
            // Same reasoning as sign-in: the raw Postgres text can carry schema
            // detail, so it is logged (redacted by OSLog) and never shown.
            log.error("account deletion failed: \(raw)")
            throw DeleteAccountError.failed
        }

        // Local sign-out only. The server-side session died with the auth user,
        // so asking it to revoke one now would fail and strand the customer on
        // a signed-in screen backing an account that no longer exists.
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
        // Anything else: a generic message. The raw provider text can carry
        // backend/config detail, so it is logged (redacted by OSLog) for
        // diagnosis rather than shown to the customer.
        log.error("sign-in failed: \(raw)")
        return "Something went wrong signing in. Please try again."
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
