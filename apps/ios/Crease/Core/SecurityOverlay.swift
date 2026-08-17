import SwiftUI
import UIKit

/// What the overlay is currently showing, so repeated sync calls don't rebuild
/// the hosted view — rebuilding LockView restarts its `.task` and re-fires the
/// Face ID prompt.
enum SecurityOverlayMode: Equatable {
    case hidden
    case lock
    case privacy
}

/// Hosts the Face ID lock and the app-switcher privacy cover in a dedicated
/// UIWindow above the normal window level.
///
/// The cover has to sit above *everything the app draws*, and a SwiftUI overlay
/// placed in RootView's ZStack does not: `.sheet` and `.fullScreenCover` are
/// UIKit presentations layered above the window's root view controller, so a
/// booking flow or the account-export share sheet rendered on top of the lock —
/// visible on the app-switcher snapshot and interactive behind it. A separate
/// window at `.alert + 1` is above those presentation contexts too, so nothing
/// the app puts on screen can escape the cover.
@MainActor
final class SecurityOverlayWindow {
    static let shared = SecurityOverlayWindow()
    private var window: UIWindow?
    private(set) var mode: SecurityOverlayMode = .hidden

    /// Raise the Face ID lock. Marked as an accessibility modal so VoiceOver and
    /// Full Keyboard Access cannot step past it into the order data, addresses
    /// and handoff PINs beneath — an opaque overlay blocks touches but not the
    /// accessibility or focus paths.
    func showLock(_ content: some View) {
        guard mode != .lock else { return }
        present(content, mode: .lock, modalForAccessibility: true)
    }

    /// Raise the privacy cover (app leaving the foreground, lock off).
    func showPrivacy(_ content: some View) {
        guard mode != .privacy else { return }
        present(content, mode: .privacy, modalForAccessibility: false)
    }

    func hide() {
        guard mode != .hidden else { return }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        mode = .hidden
    }

    private func present(_ content: some View, mode newMode: SecurityOverlayMode, modalForAccessibility: Bool) {
        guard let scene = Self.activeScene() else { return }
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = modalForAccessibility

        let overlay = window ?? UIWindow(windowScene: scene)
        overlay.windowScene = scene
        overlay.windowLevel = .alert + 1
        overlay.rootViewController = host
        overlay.isHidden = false
        window = overlay
        mode = newMode
    }

    /// The foreground scene — including `.foregroundInactive`, so the privacy
    /// cover can be raised as the app deactivates (before the snapshot is taken),
    /// not only while it is fully active.
    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
