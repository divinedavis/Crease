import SwiftUI
import UIKit

@main
struct CreaseApp: App {
    // Push has two entry points SwiftUI does not offer: the device token, and
    // a notification tapped while the app was not running.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @StateObject private var lock = AppLock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(lock)
                .tint(Theme.accent)
        }
        // Foreground/background is watched inside RootView, from UIKit's own
        // notifications rather than `scenePhase` — see the comment there.
    }
}

/// Auth gate. `.loading` gets its own state rather than defaulting to the
/// signed-out screen, so a returning customer with a valid session never sees
/// a sign-in form flash before their orders appear.
struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var lock: AppLock

    /// Whether the app is frontmost, read from UIKit rather than SwiftUI's
    /// `scenePhase`.
    ///
    /// The privacy cover is an opaque window this app raises over itself, and
    /// `scenePhase` is not a safe input for taking it back down: it is derived
    /// per window group, and once another window in the scene is in front the
    /// phase this view sees can stay `.inactive` after the app is plainly
    /// active again. The cover then has nothing to lower it — an opaque black
    /// screen with a padlock and no way out but backgrounding the app, which
    /// is exactly what the field report showed.
    ///
    /// `didBecomeActive` / `willResignActive` come from UIApplication itself,
    /// fire regardless of which window is key, and cannot be starved by the
    /// very window they are meant to dismiss.
    @State private var appActive = UIApplication.shared.applicationState == .active

    var body: some View {
        content
            // The lock and privacy cover live in a dedicated window above every
            // sheet and cover (see SecurityOverlayWindow), not in a ZStack here
            // where a presented modal would render on top of them.
            .onAppear { syncOverlay() }
            .onChange(of: lock.isLocked) { _ in syncOverlay() }
            .onChange(of: isSignedIn) { _ in syncOverlay() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                appActive = false
                syncOverlay()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                appActive = true
                syncOverlay()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                // Re-engage the biometric lock as the app leaves the foreground,
                // so returning requires Face ID again. Driven from the same
                // authoritative signal for the same reason: a lock that fails to
                // engage is a security hole, not a cosmetic bug.
                lock.lockIfEnabled()
                syncOverlay()
            }
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
        } else if !appActive {
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
            // Identity keyed on the customer so signing in as someone else
            // builds a new store rather than showing them the last account's
            // orders while the fetch is in flight.
            SignedInRoot(session: session, userId: userId)
                .id(userId)
        }
    }
}

/// Owns the `OrderStore` for as long as one customer stays signed in.
///
/// This used to be `OrdersView().environmentObject(OrderStore(client:))`
/// written inline in `RootView.body`, which made a brand-new empty store on
/// every re-render — and `appActive` alone flips on the first
/// `didBecomeActive` after launch, so the very first render was reliably
/// followed by a second one. The fresh store was injected over the one
/// `OrdersView`'s `.task` had already filled, and that `.task` did not re-run
/// because the view's identity had not changed. The list then read "No orders
/// yet" for an account with three of them until a pull-to-refresh, and again
/// after every return from the background.
///
/// `@StateObject` evaluates its autoclosure once for the lifetime of the
/// view's identity, so the store now outlives a re-render.
private struct SignedInRoot: View {
    let session: Session
    let userId: UUID
    @StateObject private var store: OrderStore

    init(session: Session, userId: UUID) {
        self.session = session
        self.userId = userId
        _store = StateObject(wrappedValue: OrderStore(client: session.client))
    }

    var body: some View {
        OrdersView()
            .environmentObject(store)
            // Keyed on the customer, not on appearance: signing in as
            // someone else has to move this device's token to their row,
            // or the next "your clothes are ready" reaches the phone of
            // whoever used it before them.
            .task(id: userId) {
                await PushRegistrar.shared.customerSignedIn(userId: userId, session: session)
            }
    }
}
