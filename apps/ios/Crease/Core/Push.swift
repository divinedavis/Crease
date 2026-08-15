import CryptoKit
import OSLog
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "com.divinedavis.crease", category: "push")

/// Getting this device onto the list of things the service can notify.
///
/// The whole point of the "your clothes are ready" notification is that it
/// arrives hours later with the app closed, so none of this can depend on the
/// customer having Crease open. What it does depend on is a device token, and
/// a token is only issued once the customer has said yes — which is why the
/// prompt is fired from a finished booking rather than from launch.
///
/// Every failure here is silent by nature: an unregistered device looks
/// identical to a registered one until the notification that never comes.
/// Hence the log lines — they are the only evidence.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    private weak var session: Session?
    private var userId: UUID?

    /// The last registration the service accepted, as customer + environment +
    /// token. All three belong in the key: the same device handed to a second
    /// customer has to be re-registered under them, and a build re-signed for
    /// distribution keeps its token shape while changing which APNs it belongs
    /// to. A stale match here is a notification delivered to the wrong person
    /// or to nobody.
    private static let acceptedKey = "push.acceptedRegistration"

    private struct Registration: Encodable {
        let token: String
        let environment: String
    }

    /// Ask for permission at the one moment it explains itself.
    ///
    /// A booking has just succeeded: a driver is coming, and the next thing
    /// that happens on this order is hours away and will happen while the app
    /// is closed. Asked at launch the same prompt is a question about nothing,
    /// and the refusal it earns is permanent — iOS never shows the system
    /// alert twice. So `.denied` is left alone here rather than nagged.
    func askAfterBooking() async {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            guard let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge]),
                  granted
            else { return }
            UIApplication.shared.registerForRemoteNotifications()
        case .authorized, .provisional, .ephemeral:
            // Permission persists; a device token does not. It is reissued
            // after a restore, an OS upgrade or a long enough absence, and the
            // old one stops delivering without saying so.
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    /// A customer's session became the current one.
    ///
    /// Registration follows whoever is signed in. Without this, a device that
    /// changes hands keeps notifying the previous customer about an order that
    /// is no longer theirs, which is both a wrong notification and a leak of
    /// somebody's order status.
    func customerSignedIn(userId: UUID, session: Session) async {
        self.session = session
        self.userId = userId
        guard await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus == .authorized
        else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs answered with a token for this install.
    func received(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await send(hex) }
    }

    private func send(_ deviceToken: String) async {
        guard let session, let userId else { return }
        let registration = "\(userId.uuidString.lowercased()):\(Self.apsEnvironment):\(deviceToken)"
        // Store only a hash of the registration tuple, not the plaintext
        // userId:env:token — UserDefaults is an unencrypted plist included in
        // device backups, and the hash is all the "already registered" check
        // needs.
        let registrationHash = SHA256.hash(data: Data(registration.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard registrationHash != UserDefaults.standard.string(forKey: Self.acceptedKey) else { return }
        guard let accessToken = try? await session.client.auth.session.accessToken else { return }

        do {
            _ = try await DispatchAPI(accessToken: accessToken).post(
                "/v1/me/push-tokens",
                body: Registration(token: deviceToken, environment: Self.apsEnvironment),
                as: DispatchAPI.Ack.self
            )
            UserDefaults.standard.set(registrationHash, forKey: Self.acceptedKey)
        } catch {
            // Deliberately not recorded, so every later registration retries
            // it. The route can be absent in an environment that has not been
            // deployed yet, and a device that quietly stopped being registered
            // is a customer who stops being told anything.
            log.error("device token not registered: \(error.localizedDescription)")
        }
    }

    /// Which APNs this build actually registered against.
    ///
    /// Read from the signed profile, never from `#if DEBUG`. A TestFlight
    /// build is a Release build signed for distribution, so it holds a
    /// PRODUCTION token — and a sender told "sandbox" for it has every push
    /// rejected as a bad device token, at the sender, where nobody is looking.
    /// No profile at all means the simulator, which only has sandbox.
    static var apsEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8)),
              let profile = try? PropertyListSerialization.propertyList(
                  from: Data(raw[start.lowerBound..<end.upperBound]), format: nil
              ) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return "sandbox" }
        return environment == "production" ? "production" : "sandbox"
    }
}

/// Where a tapped notification lands.
///
/// Held as an id rather than acted on immediately: a notification tapped while
/// the app was not running is delivered before any order has been loaded, so
/// the screen that can resolve it does not exist yet.
@MainActor
final class PushRouter: ObservableObject {
    static let shared = PushRouter()

    @Published var pendingOrderId: UUID?

    func handle(_ userInfo: [AnyHashable: Any]) {
        // `orderId` is what the sender writes; the snake_case fallback is for
        // the rest of the API's spelling, because a tap that silently does
        // nothing is indistinguishable from a notification nobody sent.
        guard let raw = (userInfo["orderId"] ?? userInfo["order_id"]) as? String,
              let id = UUID(uuidString: raw)
        else {
            log.error("notification carried no order id")
            return
        }
        pendingOrderId = id
    }
}

/// UIKit's half of push.
///
/// SwiftUI exposes neither piece: the device token is delivered to the
/// application delegate, and a notification tapped from a cold start arrives
/// before any scene exists.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Must be set before launch finishes or the tap that woke the app is
        // delivered to nobody and opens the order list instead of the order.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistrar.shared.received(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on a simulator and on any build whose profile carries no
        // aps-environment. Fatal to the feature everywhere else, and there is
        // nothing on screen that would ever show it.
        log.error("APNs refused registration: \(error.localizedDescription)")
    }

    /// A notification that lands while the customer is looking at the app is
    /// still worth showing. The alternative is the update arriving invisibly
    /// on the one screen that was already open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            PushRouter.shared.handle(response.notification.request.content.userInfo)
        }
    }
}
