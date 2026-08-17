import SwiftUI

@main
struct CreaseApp: App {
    // Push has two entry points SwiftUI does not offer: the device token, and
    // a notification tapped while the app was not running.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(lock)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { phase in
            // Re-engage the lock as the app leaves the foreground, so returning
            // requires Face ID again.
            if phase == .background { lock.lockIfEnabled() }
        }
    }
}

/// Auth gate. `.loading` gets its own state rather than defaulting to the
/// signed-out screen, so a returning customer with a valid session never sees
/// a sign-in form flash before their orders appear.
struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            // The lock and privacy cover live in a dedicated window above every
            // sheet and cover (see SecurityOverlayWindow), not in a ZStack here
            // where a presented modal would render on top of them. Drive that
            // window from the same three inputs the ZStack used to switch on.
            .onAppear { syncOverlay() }
            .onChange(of: lock.isLocked) { _ in syncOverlay() }
            .onChange(of: scenePhase) { _ in syncOverlay() }
            .onChange(of: isSignedIn) { _ in syncOverlay() }
    }

    /// Whether there is an authenticated session to guard. Only a signed-in
    /// customer has orders/address/PIN on screen worth covering.
    private var isSignedIn: Bool {
        if case .signedIn = session.state { return true }
        return false
    }

    private func syncOverlay() {
        guard isSignedIn else { SecurityOverlayWindow.shared.hide(); return }
        if lock.isLocked {
            SecurityOverlayWindow.shared.showLock(LockView().environmentObject(lock))
        } else if scenePhase != .active {
            SecurityOverlayWindow.shared.showPrivacy(PrivacyCover())
        } else {
            SecurityOverlayWindow.shared.hide()
        }
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
        case .signedOut:
            SignInView()
        case let .signedIn(userId):
            OrdersView()
                .environmentObject(OrderStore(client: session.client))
                // Keyed on the customer, not on appearance: signing in as
                // someone else has to move this device's token to their row,
                // or the next "your clothes are ready" reaches the phone of
                // whoever used it before them.
                .task(id: userId) {
                    await PushRegistrar.shared.customerSignedIn(userId: userId, session: session)
                }
        }
    }
}
