import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign-in.
///
/// Apple first, because it is one tap and gives us a verified identity without
/// asking the customer for anything. Email is a 6-digit code, never a magic
/// link — a link throws people into a mail app and frequently a different
/// browser, losing the session and whatever they were part-way through.
struct SignInView: View {
    @EnvironmentObject private var session: Session

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var currentNonce = ""
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 48)

                Text("Crease")
                    .font(.largeTitle.weight(.semibold))
                Text("Dry cleaning, picked up and delivered.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                Spacer(minLength: 44)

                SignInWithAppleButton(.signIn) { request in
                    let nonce = Self.randomNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    Text("or").font(.footnote).foregroundStyle(.secondary)
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                }
                .padding(.vertical, 22)

                if codeSent {
                    Text("We sent a 6-digit code to \(email).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)

                    TextField("123456", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .focused($focus, equals: .code)
                        .accessibilityLabel("Six digit code")

                    Button {
                        Task {
                            busy = true
                            await session.verifyEmailCode(email: email, code: code)
                            busy = false
                        }
                    } label: {
                        Label("Continue", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(code.count < 6 || busy)
                    .padding(.top, 14)

                    Button("Use a different email") {
                        codeSent = false
                        code = ""
                    }
                    .font(.footnote)
                    .padding(.top, 12)
                } else {
                    TextField("you@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .accessibilityLabel("Email address")

                    Button {
                        Task {
                            busy = true
                            if await session.sendEmailCode(to: email) {
                                codeSent = true
                                focus = .code
                            }
                            busy = false
                        }
                    } label: {
                        Text("Email me a code").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!email.contains("@") || busy)
                    .padding(.top, 14)
                }

                if let error = session.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 14)
                }

                Spacer(minLength: 40)

                Text("No password to remember, and nothing to confirm in your inbox.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .overlay { if busy { ProgressView().controlSize(.large) } }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        guard case let .success(auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            session.errorMessage = "Apple sign-in didn't complete."
            return
        }
        Task {
            busy = true
            await session.signInWithApple(idToken: token, nonce: currentNonce)
            busy = false
        }
    }

    /// Apple requires the raw nonce at exchange time and its SHA-256 in the
    /// request; sending the same value for both defeats the replay protection.
    private static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        for _ in 0..<length {
            result.append(chars[Int.random(in: 0..<chars.count)])
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
