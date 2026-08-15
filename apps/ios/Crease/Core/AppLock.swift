import SwiftUI

/// A local Face ID / Touch ID gate over an already-authenticated Supabase
/// session.
///
/// It does NOT replace the auth token — the customer signs in once (Apple /
/// Google), and the session lives in the Keychain. This keeps the app's
/// contents (orders, home address, access notes, courier handoff PIN) behind a
/// biometric check on cold launch and on every return from the background, and
/// doubles as the privacy cover so the app-switcher snapshot shows nothing.
@MainActor
final class AppLock: ObservableObject {
    /// Whether the customer turned the lock on. Persisted per install.
    @Published private(set) var isEnabled: Bool
    /// True when the lock is engaged and the app must stay hidden until unlocked.
    @Published private(set) var isLocked: Bool
    /// Guards against overlapping biometric prompts.
    private var authenticating = false
    /// Drives the one-time "want to turn this on?" alert after signing in.
    @Published var isOfferingOptIn = false

    /// What this device offers (drives the button label / icon).
    let biometry = BiometricAuth.kind()

    private static let key = "app.lock.biometricEnabled"
    private static let offeredKey = "app.lock.optInOffered"

    init() {
        #if DEBUG
        // The offer is once per install, which would let the UI test pass on a
        // fresh simulator and never again. Clearing both keys is what makes
        // the run repeatable.
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetLockOptIn") {
            UserDefaults.standard.removeObject(forKey: Self.offeredKey)
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        #endif
        let enabled = UserDefaults.standard.bool(forKey: Self.key)
        isEnabled = enabled
        // If the lock is on, a cold launch starts locked.
        isLocked = enabled
    }

    /// Offer the lock once, just after signing in.
    ///
    /// The menu toggle is the only way to discover this today, which means
    /// nobody does — and the one screen where the offer makes sense is the one
    /// right after an account appears on the device. Asked once and never
    /// again: this is a preference, not a permission, so a second ask is
    /// nagging rather than a second chance. Devices with no enrolled biometry
    /// are never asked, because the answer could only be no.
    func offerOptInIfNeverAsked() {
        guard !UserDefaults.standard.bool(forKey: Self.offeredKey),
              biometry != .none,
              !isEnabled
        else { return }
        isOfferingOptIn = true
    }

    /// Customer said yes. `setEnabled` runs the biometric check, so declining
    /// that check leaves the lock off rather than half-on.
    func acceptOptIn() async {
        markOffered()
        await setEnabled(true)
    }

    func declineOptIn() {
        markOffered()
    }

    /// Recorded when the customer answers, not when the alert appears: an app
    /// killed mid-prompt should still get its one ask.
    private func markOffered() {
        isOfferingOptIn = false
        UserDefaults.standard.set(true, forKey: Self.offeredKey)
    }

    /// Re-engage the lock when the app leaves the foreground.
    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    /// Prompt for Face ID / Touch ID to reveal the app. Safe to call repeatedly
    /// (e.g. from `.task` on the lock screen) — overlapping prompts are ignored.
    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await BiometricAuth.authenticate(reason: "Unlock Crease") {
            isLocked = false
        }
    }

    /// Toggle the lock from settings. Both directions require a successful
    /// biometric check, so an unlocked-but-unattended phone can't be used to
    /// silently disable the lock, and we never enable it for someone who can't
    /// pass the check (locking them out).
    func setEnabled(_ on: Bool) async {
        guard on != isEnabled else { return }
        let reason = on ? "Turn on \(biometry.label) lock" : "Turn off \(biometry.label) lock"
        guard await BiometricAuth.authenticate(reason: reason) else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.key)
        isLocked = false // just authenticated
    }
}
