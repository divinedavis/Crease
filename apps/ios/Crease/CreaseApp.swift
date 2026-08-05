import SwiftUI

@main
struct CreaseApp: App {
    // Push has two entry points SwiftUI does not offer: the device token, and
    // a notification tapped while the app was not running.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .tint(Theme.accent)
        }
    }
}

/// Auth gate. `.loading` gets its own state rather than defaulting to the
/// signed-out screen, so a returning customer with a valid session never sees
/// a sign-in form flash before their orders appear.
struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
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
