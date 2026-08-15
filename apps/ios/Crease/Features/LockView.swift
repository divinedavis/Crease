import SwiftUI

/// Full-screen cover shown while the biometric lock is engaged. Auto-prompts on
/// appear and offers a manual retry (e.g. after the customer cancels the sheet).
struct LockView: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: lock.biometry == .touchID ? "touchid" : "faceid")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text("Crease is locked")
                    .font(.title2.weight(.semibold))
                Text("Unlock with \(lock.biometry.label) to see your orders.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 48)
                .padding(.top, 6)
            }
            .padding(40)
        }
        .task { await lock.unlock() }
    }
}

/// Opaque cover shown whenever the app is not active (so the backgrounded
/// snapshot in the app switcher never reveals orders / address / PIN), even
/// when the biometric lock itself is off.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
        }
    }
}
