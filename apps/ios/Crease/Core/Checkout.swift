import Foundation
import StripePaymentSheet
import SwiftUI

/// Taking the delivery fee.
///
/// Crease charges for transport only — the cleaning bill is settled with the
/// shop — so the amount is known the moment a tier is chosen. That makes this
/// a plain charge rather than the authorize-then-capture flow the cleaning
/// total requires, and it means the customer sees a final number, not a hold.
///
/// The client secret is minted server-side and is the only payment credential
/// this app ever holds. The publishable key comes from the same call rather
/// than being compiled in, so rotating it does not need a release.
@MainActor
final class Checkout: ObservableObject {
    enum State: Equatable {
        case idle
        case working
        case paid
        case failed(String)
        /// The server priced this route above the published fee, so nothing has
        /// been presented and nothing charged. Carries the real price for the
        /// caller to put in front of the customer.
        case repriced(Int)
    }

    @Published private(set) var state: State = .idle

    /// Mint the intent, take the money, then let the server act on it.
    ///
    /// One call from end to end, and imperative on purpose. The sheet used to
    /// be handed to SwiftUI as `@Published` state and presented by
    /// `.paymentSheet(isPresented:)`, which never fired: the modifier only
    /// exists once a sheet exists, so it was installed in the same update that
    /// already had the binding true and there was no false→true edge left for
    /// it to observe. Presenting directly removes the race instead of trying
    /// to out-time it.
    ///
    /// The access token is the customer's own; the server checks the order
    /// belongs to them. No shared secret ships in this app.
    ///
    /// Returns the dispatcher's answer when the money moved, because "paid" is
    /// not the same as "a driver is coming" and the caller has to be able to
    /// tell those apart.
    /// - Parameter agreedCents: the price the customer actually saw and tapped.
    ///   The published tier prices assume the flat-rate courier band; a route
    ///   outside it costs more than that fee collects, so the server prices the
    ///   real route when it mints the intent. Charging the difference silently
    ///   would take money against a number nobody agreed to, so a higher price
    ///   comes back as `.repriced` and the sheet is never presented — the
    ///   caller asks, and calls again with the new figure if they say yes.
    func pay(orderId: UUID, accessToken: String, agreedCents: Int) async -> Confirmation? {
        state = .working

        let api = DispatchAPI(accessToken: accessToken)
        guard api.isConfigured else {
            state = .failed("Payments are not configured in this build.")
            return nil
        }
        let order = "/v1/me/orders/\(orderId.uuidString.lowercased())"

        // The screen the customer tapped from, read before any network hop and
        // compared against the top of the stack when the sheet is ready. A
        // booking takes a second or two to mint an intent, and whatever is
        // topmost after that is not necessarily what they were looking at when
        // they agreed to pay.
        let origin = Self.topViewController()

        // Whether the card has been charged by the time something goes wrong.
        // Everything after the sheet closes can still fail, and a failure on
        // that side of the line needs an entirely different sentence.
        var charged = false

        do {
            let intent: IntentResponse = try await api.post(
                order + "/payment-intent",
                as: IntentResponse.self
            )
            guard let secret = intent.clientSecret,
                  let publishable = intent.publishableKey, !publishable.isEmpty
            else {
                state = .failed(intent.error ?? "Couldn't start payment.")
                return nil
            }

            // An intent that already succeeded must not be presented a second
            // time: Stripe refuses it, and the customer reads that refusal as
            // their payment failing. Skip straight to confirmation, which is
            // also how a booking whose confirm call was lost gets finished.
            charged = intent.alreadyPaid == true

            // Stop before the sheet if the price moved. Only upward: a server
            // price at or below what they tapped is theirs to have, and an
            // order already paid has no price left to renegotiate.
            if !charged, let priced = intent.amountCents, priced > agreedCents {
                state = .repriced(priced)
                return nil
            }

            if !charged {
                STPAPIClient.shared.publishableKey = publishable

                var config = PaymentSheet.Configuration()
                config.merchantDisplayName = "Crease"
                config.applePay = .init(
                    merchantId: "merchant.com.divinedavis.crease",
                    merchantCountryCode: "US"
                )
                // Apple Pay first: it is one authentication instead of typing a
                // card, and it is why most people finish a checkout on a phone.
                config.primaryButtonColor = UIColor(Theme.accent)
                config.allowsDelayedPaymentMethods = false

                // Two refusals in one. A controller that is off-window or on
                // its way out never gets a sheet on screen, and Stripe only
                // calls back from a sheet that made it there — so presenting
                // into one awaits a continuation nobody will ever resume, and
                // the button that started it reads "Booking…" until the app is
                // killed. A controller that is simply not the one they started
                // from is worse: the sheet does appear, over whatever screen
                // they moved on to, and paying it books a courier for a
                // booking they walked away from.
                guard let presenter = Self.topViewController(), presenter === origin,
                      presenter.isViewLoaded, presenter.view.window != nil,
                      !presenter.isBeingDismissed
                else {
                    state = .failed("Couldn't open the payment sheet. Try again.")
                    return nil
                }
                let sheet = PaymentSheet(paymentIntentClientSecret: secret, configuration: config)
                switch await sheet.presented(from: presenter) {
                case .completed:
                    charged = true
                case .canceled:
                    // Not a failure — the customer changed their mind, and
                    // telling them something went wrong would be a lie.
                    state = .idle
                    return nil
                case let .failed(error):
                    state = .failed(error.localizedDescription)
                    return nil
                }
            }

            // The server decides an order is paid, never this. It re-reads the
            // intent from the provider before it promotes anything, so a sheet
            // that reported success against an intent that did not settle
            // dispatches nobody.
            let confirmation: Confirmation = try await api.post(
                order + "/confirm-payment",
                as: Confirmation.self
            )
            state = .paid
            return confirmation
        } catch {
            // Paid, and no courier would take it. The server has already said
            // the only useful thing — cancel it and take the money back — and
            // the retry sentence below would contradict that in the same
            // breath. Retrying cannot work either: the order has left 'draft'
            // by now and the intent route refuses anything that has.
            if let failure = error as? DispatchAPI.Failure, failure.code == "no_courier" {
                state = .failed(failure.message)
                return nil
            }
            // Past the sheet, the card has been charged and the error is only
            // about finishing the booking. Left unsaid, the customer reads
            // "The request timed out." under a button still offering to take
            // their money and assumes either nothing happened or that tapping
            // again pays twice. Neither is true.
            state = .failed(charged
                ? "Your card was charged. We couldn't finish booking the driver. Tap again to finish — you won't be charged twice."
                : "Something went wrong. Please try again.")
            return nil
        }
    }

    /// The controller Stripe presents from.
    ///
    /// Resolved at present time rather than captured earlier: booking runs
    /// inside a `fullScreenCover`, so the root controller already has
    /// something presented and presenting from it trips Stripe's
    /// `alreadyPresented` assertion. Walking to the deepest presented
    /// controller finds whatever is actually on screen, wherever checkout was
    /// started from.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    struct IntentResponse: Decodable {
        let ok: Bool?
        let clientSecret: String?
        let publishableKey: String?
        let amountCents: Int?
        let alreadyPaid: Bool?
        let error: String?
    }

    /// The dispatcher's verdict. A 402 or 409 arrives as a thrown `Failure`
    /// carrying the server's reason, so anything decoded here means the money
    /// moved — which is not the same as the order being on its way.
    struct Confirmation: Decodable {
        let ok: Bool?
        let outcome: String?
        let paymentStatus: String?
        let orderStatus: String?
        /// False is legitimate on exactly one tier — return-only, which has no
        /// pickup leg to book. Anywhere else it is a paid order with no
        /// courier, which is why `problem` needs the tier to read it.
        let dispatched: Bool?
        /// The dispatch failure, carried on a 200 because the charge itself
        /// succeeded. Ignoring it is how "we took your money and found nobody
        /// to collect your bag" gets handled as a clean booking.
        let error: String?
        /// The courier leg, when the dispatcher had one to report. Its
        /// presence next to `dispatched: false` is what separates "a driver
        /// was booked by an earlier call" from "no driver was booked at all",
        /// which are opposite things to tell someone whose card just cleared.
        let leg: Leg?

        struct Leg: Decodable {
            let status: String?
        }

        /// Why this is not a booking yet, if it is not one.
        ///
        /// A 200 here means the money moved; it does not mean a courier did.
        /// Nothing else distinguishes the two, so without this the screen
        /// closes on a success animation and a paid order with no driver goes
        /// into the list as though it were on its way. Read broadly on
        /// purpose — the dispatcher reports the same fact through `outcome`,
        /// `error`, `dispatched` and the order's own status, and only one of
        /// them has to arrive for the customer to deserve the truth.
        ///
        /// The tier is a parameter because `dispatched: false` cannot be
        /// judged without it: it is the correct, ordinary answer for a
        /// return-only order, which has no pickup leg to book, and on every
        /// other tier it means a charge with no courier behind it.
        func problem(serviceTier: String) -> String? {
            if outcome == "processing" {
                return "Your bank is still confirming this payment, so no driver is booked yet. We'll book one as soon as it clears — you don't need to pay again."
            }
            if ok == false || outcome == "dispatch_failed"
                || error != nil || orderStatus == "failed" {
                return "Your payment went through, but we couldn't find a driver. Nothing has been collected — cancel this order for a refund, or leave it with us and we'll try to book one again."
            }
            // Paid, 'confirmed', and still nobody dispatched. The service
            // answers this when the order had already been cancelled or
            // delivered, when it lost the promote-out-of-draft race, or when a
            // pickup leg already existed — none of which is a courier this
            // call arranged, and all of which used to play the success
            // animation and dismiss over a charged card.
            //
            // Absent counts as false: this field is the only evidence a
            // courier was booked, and missing evidence is not evidence.
            guard dispatched != true, serviceTier != "return_only" else { return nil }
            if let leg {
                // Not a failure — the pickup this order needed already exists,
                // almost always because the confirm whose reply never reached
                // the phone did its job. Worth saying anyway: the screen must
                // not present someone else's earlier booking as this one.
                return leg.status == "delivered"
                    ? "Your bag has already been collected on this order, so no second driver was booked. You haven't been charged twice."
                    : "A driver was already booked for this order, so we didn't send a second one. You haven't been charged twice — open the order to track them."
            }
            switch orderStatus {
            case "cancelled":
                return "This order was already cancelled, so no driver has been booked. If your card was charged, contact support and we'll refund it."
            case "delivered":
                return "This order is already finished, so no driver has been booked. If your card was charged, contact support and we'll refund it."
            default:
                return "Your payment went through, but no driver has been booked for this order. Nothing has been collected — contact support and we'll either send one or refund you."
            }
        }
    }
}

private extension PaymentSheet {
    /// `@MainActor` is load-bearing, not decoration. Without it this is a
    /// nonisolated async function, so awaiting it from `pay` hops off the main
    /// actor and Stripe builds its bottom sheet on a background thread —
    /// UIKit's view-hierarchy assertion fires and the app aborts before the
    /// sheet ever draws.
    @MainActor
    func presented(from presenter: UIViewController) async -> PaymentSheetResult {
        await withCheckedContinuation { continuation in
            // Stripe really does call this twice: dismissing the loading sheet
            // fires `.canceled` and clears its stored completion, and the load
            // still in flight then calls this closure directly, which nothing
            // on their side nil-guards. A second `resume` is a fatalError in
            // Release as well as Debug — the app dies mid-checkout. The old
            // declarative path shrugged a double call off, so the one-shot is
            // owed to the bridge, not to Stripe.
            var resumed = false
            present(from: presenter) { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
    }
}
