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
        case preparing
        case ready(PaymentSheet)
        case paid
        case failed(String)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.preparing, .preparing), (.paid, .paid): true
            case let (.failed(x), .failed(y)): x == y
            case (.ready, .ready): true
            default: false
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// Non-nil exactly when a sheet is ready to present.
    @Published var sheet: PaymentSheet?
    @Published var isPresenting = false

    /// Ask the server for an intent and build the sheet around it.
    ///
    /// The access token is the customer's own; the server checks the order
    /// belongs to them. No shared secret ships in this app.
    func prepare(orderId: UUID, accessToken: String) async {
        state = .preparing

        let api = DispatchAPI(accessToken: accessToken)
        guard api.isConfigured else {
            state = .failed("Payments are not configured in this build.")
            return
        }

        do {
            let body: IntentResponse = try await api.post(
                "/v1/me/orders/\(orderId.uuidString.lowercased())/payment-intent",
                as: IntentResponse.self
            )
            guard let secret = body.clientSecret,
                  let publishable = body.publishableKey, !publishable.isEmpty
            else {
                state = .failed(body.error ?? "Couldn't start payment.")
                return
            }

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

            let built = PaymentSheet(paymentIntentClientSecret: secret, configuration: config)
            sheet = built
            state = .ready(built)
            isPresenting = true
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func handle(_ result: PaymentSheetResult) {
        isPresenting = false
        sheet = nil
        switch result {
        case .completed:
            state = .paid
        case .canceled:
            // Not a failure — the customer changed their mind, and telling them
            // something went wrong would be a lie.
            state = .idle
        case let .failed(error):
            state = .failed(error.localizedDescription)
        }
    }

    struct IntentResponse: Decodable {
        let ok: Bool?
        let clientSecret: String?
        let publishableKey: String?
        let amountCents: Int?
        let alreadyPaid: Bool?
        let error: String?
    }
}
