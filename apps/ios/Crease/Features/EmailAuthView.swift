import SwiftUI

/// Email and password, in one sheet that is both the sign-in and the sign-up.
///
/// The shape is the one the Hidden Gems app already uses: a mode that flips in
/// place rather than a second screen, underlined fields instead of boxes, and a
/// single capsule action at the bottom. Flipping in place matters more than it
/// looks — the two forms differ by two fields, so re-presenting a sheet to
/// swap them makes people who tapped the wrong one feel they have lost their
/// place and re-type what they already typed.
///
/// Nothing here sends anyone to their inbox. The Supabase project auto-confirms
/// addresses, so creating an account returns a session on the spot; a
/// confirmation link would put a mail app between someone and their first
/// order, which is the whole reason the rest of the screen is OAuth.
struct EmailAuthSheet: View {
    /// The 40 pt headline, scaled with the reader's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    enum Mode { case signIn, signUp }
    enum Field { case name, email, password, confirm }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var fullName = ""
    @State private var isSubmitting = false
    @FocusState private var focused: Field?

    /// Follows the system so the sheet is readable in dark mode. Hidden Gems
    /// paints its own near-black on white; Crease's other screens are all
    /// system-coloured, and a hardcoded white sheet in front of them reads as
    /// a different app.
    private let ink = Color(.label)

    private var passwordsMatch: Bool {
        mode == .signIn || (password == confirmPassword && !confirmPassword.isEmpty)
    }

    private var canSubmit: Bool {
        let emailOk = !email.trimmingCharacters(in: .whitespaces).isEmpty
        // Matches the server policy, so the button is never enabled for a
        // password the server is about to refuse.
        //
        // TEMPORARY, 2026-08-19: relaxed to 6 with Supabase's leaked-password
        // (HIBP) check switched off, at the owner's request, so throwaway
        // passwords work while testing. Put both back — 8 here, and
        // password_min_length 8 + password_hibp_enabled true on the Supabase
        // project — before the App Store submission.
        let pwOk = password.count >= 6
        let nameOk = mode == .signIn || !fullName.trimmingCharacters(in: .whitespaces).isEmpty
        return emailOk && pwOk && nameOk && passwordsMatch
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        CircleIconButton(symbol: "xmark", label: "Cancel") { dismiss() }
                        Spacer()
                    }
                    .padding(.bottom, 18)

                    // The door with a bag on the step: what joining gets you.
                    IllustrationTile(art: .welcome, size: 120, corner: 34, inset: 0.08)
                        .padding(.bottom, 18)

                    Text(mode == .signIn ? "Welcome back." : "Let's get started.")
                        .font(.app(.subheadline))
                        .foregroundStyle(ink.opacity(0.55))
                        .padding(.bottom, 8)
                        .contentTransition(.opacity)

                    Text(mode == .signIn ? "Sign in to\nyour orders." : "Join\nCrease.")
                        .font(.app(size: titleSize).weight(.bold))   // scales with Dynamic Type
                        .accessibilityLabel(mode == .signIn ? "Sign in to your orders." : "Join Crease.")
                        .foregroundStyle(ink)
                        .lineSpacing(-4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                        .contentTransition(.opacity)

                    Text("Laundry and dry cleaning, picked up from your door and brought back.")
                        .font(.app(.subheadline))
                        .foregroundStyle(ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 28)

                    VStack(spacing: 12) {
                        if mode == .signUp {
                            UnderlinedField(
                                "Full name",
                                text: $fullName,
                                ink: ink,
                                field: .name,
                                focused: $focused
                            )
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .onSubmit { focused = .email }
                        }

                        UnderlinedField(
                            "Email",
                            text: $email,
                            ink: ink,
                            field: .email,
                            focused: $focused
                        )
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focused = .password }

                        UnderlinedSecureField(
                            "Password",
                            text: $password,
                            ink: ink,
                            field: .password,
                            focused: $focused
                        )
                        .textContentType(mode == .signIn ? .password : .newPassword)
                        .submitLabel(mode == .signIn ? (canSubmit ? .go : .return) : .next)
                        .onSubmit {
                            if mode == .signIn {
                                if canSubmit { submit() }
                            } else {
                                focused = .confirm
                            }
                        }

                        if mode == .signUp {
                            UnderlinedSecureField(
                                "Confirm password",
                                text: $confirmPassword,
                                ink: ink,
                                field: .confirm,
                                focused: $focused
                            )
                            .textContentType(.newPassword)
                            .submitLabel(canSubmit ? .join : .return)
                            .onSubmit {
                                if canSubmit { submit() }
                            }
                        }
                    }
                    .padding(.bottom, 20)

                    if mode == .signUp, !confirmPassword.isEmpty, password != confirmPassword {
                        Label("Passwords don't match.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                            .font(.app(.footnote))
                            .padding(.bottom, 12)
                    } else if let error = session.errorMessage {
                        Text(error)
                            .foregroundStyle(Theme.danger)
                            .font(.app(.footnote))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)   // so a support conversation can quote it
                            .padding(.bottom, 12)
                    }

                    Button {
                        submit()
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView().tint(Theme.onInk)
                            } else {
                                Text(mode == .signIn ? "Sign In" : "Create Account")
                                    .font(.app(.headline))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .foregroundStyle(Theme.onInk)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.accentFill))
                    }
                    .disabled(!canSubmit || isSubmitting)
                    .opacity(canSubmit ? 1 : 0.4)
                    .padding(.top, 8)

                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                mode = (mode == .signIn) ? .signUp : .signIn
                                confirmPassword = ""
                                session.errorMessage = nil
                            }
                        } label: {
                            Text(mode == .signIn
                                 ? "Don't have an account? Sign up"
                                 : "Already have an account? Sign in")
                                .font(.app(.footnote))
                                .foregroundStyle(Theme.muted)
                                .contentTransition(.opacity)
                                .frame(minHeight: 44)   // Apple's 44 pt hit target
                                .contentShape(Rectangle())
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: session.state) { _, newState in
            if case .signedIn = newState { dismiss() }
        }
    }

    private func submit() {
        focused = nil
        isSubmitting = true
        Task {
            switch mode {
            case .signIn:
                await session.signInWithEmail(email: email, password: password)
            case .signUp:
                await session.signUpWithEmail(
                    email: email,
                    password: password,
                    fullName: fullName
                )
            }
            isSubmitting = false
        }
    }
}

// MARK: - Fields (soft grey boxes since 2026-11-06; the names stayed)

/// A field whose label sits above it and stays visible while typing.
///
/// The plain placeholder disappears the moment there is text in the field,
/// which on a form this short is enough to leave someone who tabbed away
/// unsure which box holds what. The label deepens on focus so the active row
/// is obvious without a box around it.
private struct UnderlinedField: View {
    let label: String
    @Binding var text: String
    let ink: Color
    let field: EmailAuthSheet.Field
    @FocusState.Binding var focused: EmailAuthSheet.Field?

    init(
        _ label: String,
        text: Binding<String>,
        ink: Color,
        field: EmailAuthSheet.Field,
        focused: FocusState<EmailAuthSheet.Field?>.Binding
    ) {
        self.label = label
        self._text = text
        self.ink = ink
        self.field = field
        self._focused = focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.app(.footnote).weight(.medium))
                .foregroundStyle(focused == field ? ink : ink.opacity(0.55))
                .animation(.easeInOut(duration: 0.15), value: focused)
            TextField("", text: $text)
                .focused($focused, equals: field)
                .font(.app(.body))
                .foregroundStyle(ink)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(focused == field ? ink : .clear, lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.15), value: focused)
                // The caption above is a separate Text, so without this the
                // field itself is nameless to VoiceOver — and to XCUITest.
                .accessibilityLabel(label)
        }
    }
}

private struct UnderlinedSecureField: View {
    let label: String
    @Binding var text: String
    let ink: Color
    let field: EmailAuthSheet.Field
    @FocusState.Binding var focused: EmailAuthSheet.Field?

    init(
        _ label: String,
        text: Binding<String>,
        ink: Color,
        field: EmailAuthSheet.Field,
        focused: FocusState<EmailAuthSheet.Field?>.Binding
    ) {
        self.label = label
        self._text = text
        self.ink = ink
        self.field = field
        self._focused = focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.app(.footnote).weight(.medium))
                .foregroundStyle(focused == field ? ink : ink.opacity(0.55))
                .animation(.easeInOut(duration: 0.15), value: focused)
            SecureField("", text: $text)
                .focused($focused, equals: field)
                .font(.app(.body))
                .foregroundStyle(ink)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(focused == field ? ink : .clear, lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.15), value: focused)
                .accessibilityLabel(label)
        }
    }
}

#Preview("Email auth") {
    Theme.canvas
        .sheet(isPresented: .constant(true)) {
            EmailAuthSheet().environmentObject(Session())
        }
}
