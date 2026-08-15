import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign-in.
///
/// Two taps, both of them OAuth, and nothing that sends anyone to their inbox —
/// no confirmation link and no emailed code. A mail round trip between someone
/// and their first order loses a real share of them, and an emailed six-digit
/// code is barely better than the confirmation link it replaces: it is still a
/// trip to another app and back.
///
/// The cost of that choice is that both providers have to work. There is no
/// email path to fall back on, so a misconfigured provider is a locked door.
struct SignInView: View {
    @EnvironmentObject private var session: Session

    @State private var busy = false
    @State private var currentNonce = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 64)

                Text("Crease")
                    .font(.largeTitle.weight(.semibold))
                Text("Dry cleaning, picked up and delivered.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                Spacer(minLength: 52)

                SignInWithAppleButton(.continue) { request in
                    let nonce = Self.randomNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task {
                        busy = true
                        await session.signInWithGoogle()
                        busy = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "g.circle.fill")
                            .font(.title3)
                        Text("Continue with Google")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 12)
                .accessibilityLabel("Continue with Google")

                if let error = session.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .textSelection(.enabled)   // so a support conversation can quote it
                }

                Spacer(minLength: 44)

                Text("No password, and nothing to confirm in your inbox.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .overlay { if busy { ProgressView().controlSize(.large) } }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        // Report what Apple actually said. Collapsing every failure into one
        // sentence made an on-device failure impossible to diagnose: Apple's
        // own sheet says "Sign Up Not Completed" and the app added nothing, so
        // there was no way to tell a cancelled tap from a misconfigured App ID
        // from a server-side rejection.
        if case let .failure(error) = result {
            let ns = error as NSError
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                session.errorMessage = nil          // user tapped X; not an error
            } else {
                session.errorMessage =
                    "Apple sign-in failed — \(ns.domain) \(ns.code). \(ns.localizedDescription)"
            }
            return
        }

        guard case let .success(auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential
        else {
            session.errorMessage = "Apple returned an unexpected credential type."
            return
        }
        guard let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            session.errorMessage = "Apple returned no identity token."
            return
        }

        Task {
            busy = true
            await session.signInWithApple(idToken: token, nonce: currentNonce)
            busy = false
        }
    }

    /// Apple requires the raw nonce at token exchange and its SHA-256 in the
    /// request; sending the same value for both defeats the replay protection.
    private static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
