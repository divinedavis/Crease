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
    let etaMinutes: Int
    let symbol: String
    /// How many courier trips we pay for. Drives the margin, and it is the
    /// only lever that meaningfully moves it.
    let legs: Int
    let isRecommended: Bool

    static let all: [ServiceOption] = [
        ServiceOption(
            id: "round_trip",
            name: "Round trip",
            blurb: "We collect it and bring it back",
            priceCents: 2995,
            etaMinutes: 30,
            symbol: "arrow.triangle.2.circlepath",
            legs: 2,
            isRecommended: false
        ),
        ServiceOption(
            id: "return_only",
            name: "Return only",
            blurb: "You drop it off, we deliver it back",
            priceCents: 1995,
            etaMinutes: 30,
            symbol: "arrow.down.circle",
            legs: 1,
            isRecommended: true
        ),
        ServiceOption(
            id: "pickup_only",
            name: "Pickup only",
            blurb: "We collect it, you fetch it from the shop",
            priceCents: 1995,
            etaMinutes: 20,
            symbol: "arrow.up.circle",
            legs: 1,
            isRecommended: false
        ),
    ]

    static var recommended: ServiceOption { all.first(where: \.isRecommended) ?? all[0] }
}
