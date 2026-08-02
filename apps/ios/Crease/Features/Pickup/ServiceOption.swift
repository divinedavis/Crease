import Foundation

/// What Crease sells: transport, not cleaning.
///
/// The customer settles the cleaning bill with the shop. These prices cover
/// couriers and card fees only, which is why they look like what they are —
/// two Uber trips cost roughly two Uber fares, and pretending otherwise is how
/// a delivery business loses money on every order.
///
/// The numbers come from live Uber Direct quotes: $12.99 a leg in Brooklyn,
/// $25.98 a round trip, essentially flat under three miles. See
/// scripts/courier-pricing.mjs.
struct ServiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let priceCents: Int
    /// Minutes until a driver reaches the customer — the ONLY duration anyone
    /// can honestly quote at booking.
    ///
    /// It is deliberately not a promise about the whole order. How long the
    /// cleaning takes is the shop's to say, and they say it at intake; when
    /// the clothes are ready the customer picks a return time themselves.
    /// Quoting "~30 min" against a round trip implied the entire cycle fitted
    /// in half an hour, which is not true of any dry cleaning anywhere.
    let pickupEtaMinutes: Int?
    let symbol: String
    /// How many courier trips we pay for. Drives the margin, and it is the
    /// only lever that meaningfully moves it.
    let legs: Int
    let isRecommended: Bool

    static let all: [ServiceOption] = [
        ServiceOption(
            id: "round_trip",
            name: "Round trip",
            blurb: "We collect it now and deliver it back when it's ready",
            priceCents: 2995,
            pickupEtaMinutes: 30,
            symbol: "arrow.triangle.2.circlepath",
            legs: 2,
            isRecommended: false
        ),
        ServiceOption(
            id: "return_only",
            name: "Return only",
            blurb: "You drop it off, we deliver it back when it's ready",
            priceCents: 1995,
            // Nothing is collected from the customer, so there is no arrival
            // to estimate. Showing one would be inventing a number.
            pickupEtaMinutes: nil,
            symbol: "arrow.down.circle",
            legs: 1,
            isRecommended: true
        ),
        ServiceOption(
            id: "pickup_only",
            name: "Pickup only",
            blurb: "We collect it, you fetch it from the shop",
            priceCents: 1995,
            pickupEtaMinutes: 20,
            symbol: "arrow.up.circle",
            legs: 1,
            isRecommended: false
        ),
    ]

    static var recommended: ServiceOption { all.first(where: \.isRecommended) ?? all[0] }
}
