import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign-in.
///
/// Laid out the way people already expect a phone sign-in to look: the mark
/// centred, the choices at the bottom under the thumb, and no fields at all.
///
/// Three choices, and nothing that sends anyone to their inbox — no
/// confirmation link and no emailed code. A mail round trip between someone and
/// their first order loses a real share of them, and an emailed six-digit code
/// is barely better than the confirmation link it replaces: it is still a trip
/// to another app and back.
///
/// The two providers come first because they are one tap. Email is third and
/// deliberately present: with OAuth alone, a provider that is misconfigured or
/// simply not one the customer uses was a locked door with nothing behind it.
/// It opens a sheet rather than putting fields on this screen, so the common
/// case still reads as one decision — which button — and nobody is looking at
/// a keyboard they did not ask for.
struct SignInView: View {
    @EnvironmentObject private var session: Session

    @Environment(\.colorScheme) private var colorScheme
    @State private var busy = false
    @State private var currentNonce = ""
    @State private var showEmailAuth = false

    var body: some View {
        // Centred on the app mark with the buttons low on the screen, the shape
        // every consumer app has trained people to expect. Nothing above the
        // fold to read and nothing to type: on a phone the whole screen is one
        // decision, which provider.
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                IllustrationTile(art: .basket, size: 96, corner: 28, inset: 0.1)
                    .padding(.bottom, 2)

                Text("crease")
                    .font(.app(size: 46).weight(.heavy))
                    .kerning(-2.5)
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel("Crease")
                Text("Laundry & Dry Cleaning")
                    .font(.app(.headline))
                Text("Laundry, picked up and delivered.")
                    .font(.app(.subheadline))
                    .foregroundStyle(Theme.muted)
            }

            // What it is, in the reference's pin / clock / tag rows. Facts
            // only: the radius, the turnaround, and the published price.
            VStack(alignment: .leading, spacing: 0) {
                GlyphRow(symbol: "mappin.circle.fill", title: "From your door",
                         subtitle: "A courier collects within 3 miles of Fulton St")
                GlyphRow(symbol: "clock.fill", title: "Back in about 48 hours",
                         subtitle: "You pick the delivery window")
                GlyphRow(symbol: "tag.fill", title: "$2.00 a pound",
                         subtitle: "10 lb minimum · courier fee from $16.95")
            }
            .softCard(padding: 14)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    let nonce = Self.randomNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    Task {
                        busy = true
                        await session.signInWithGoogle()
                        busy = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "g.circle.fill")
                            .font(.app(.title3))
                        Text("Continue with Google")
                            .font(.app(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.label))
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1.5)
                )
                .accessibilityLabel("Continue with Google")

                Button {
                    session.errorMessage = nil
                    showEmailAuth = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .font(.app(.title3))
                        Text("Continue with email")
                            .font(.app(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.label))
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1.5)
                )
                .accessibilityLabel("Continue with email")

                if let error = session.errorMessage {
                    Text(error)
                        .font(.app(.footnote))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .textSelection(.enabled)   // so a support conversation can quote it
                }

                Text("Nothing to confirm in your inbox — you're in as soon as you sign up.")
                    .font(.app(.footnote))
                    .foregroundStyle(Theme.muted)   // .tertiary failed the contrast audit
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthSheet()
                .environmentObject(session)
                .presentationCornerRadius(28)
        }
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
