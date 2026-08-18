import Foundation

/// What the customer's own selection adds up to.
///
/// A deliberate mirror of apps/portal/lib/pricing.ts — the counter and the
/// phone have to reach the same number from the same bag, or the app quotes
/// one estimate and the shop's till produces another and the difference looks
/// like a shop overcharging. The tests in ServicePricingTests use the portal's
/// own cases for exactly that reason.
///
/// It is an estimate and nothing more. What settles the bill is the shop's
/// count at intake; this decides how large a hold to place and what the
/// customer was told before their clothes left the house.
enum ServicePricing {

    /// Units actually charged for. A laundry order lighter than the shop's
    /// weight floor still bills at the floor — a 4 lb bag against a 15 lb
    /// minimum is $33.75, and pretending otherwise on the booking screen is a
    /// surprise waiting at the counter.
    static func billableUnits(_ item: ServiceItem, entered: Double) -> Double {
        guard entered.isFinite, entered > 0 else { return 0 }
        return max(entered, item.minimumUnits)
    }

    static func lineTotalCents(_ item: ServiceItem, entered: Double) -> Int {
        Int((billableUnits(item, entered: entered) * Double(item.unitPriceCents)).rounded())
    }

    /// The whole declared bag, for the lines that have something in them.
    static func subtotalCents(_ lines: [(item: ServiceItem, entered: Double)]) -> Int {
        lines.reduce(0) { $0 + lineTotalCents($1.item, entered: $1.entered) }
    }

    /// The headroom the card is held for above the estimate.
    ///
    /// Mirrors orders.approval_threshold_cents, whose column default this is.
    /// If that default moves, move this with it — the number is shown to the
    /// customer at checkout, and a screen promising a smaller hold than Stripe
    /// then asks for is worse than not mentioning it at all.
    static let approvalThresholdCents = 1500

    /// What Stripe is asked to authorize: what the order is worth, and not a
    /// cent more. A mirror of holdForOrder in packages/payments/src/types.ts.
    ///
    /// The app has to show this because Stripe's own sheet puts it on the Pay
    /// button. It used to carry a buffer — 25% of the bill, so a $39.43 order
    /// asked for $49.29 — and a hold is a claim on somebody's available
    /// credit. On a debit card that difference is grocery money, reserved
    /// against a bag nobody has opened yet.
    ///
    /// The trade is that any count above what was declared now has to stop and
    /// ask rather than capture silently. A bag nobody itemised holds only the
    /// courier fee, and its cleaning is approved after the count by
    /// definition — nobody has ever named a price for it.
    static func holdCents(cleaningCents: Int, fixedCents: Int) -> Int {
        max(0, cleaningCents) + max(0, fixedCents)
    }

    /// Whether the weight floor — not the bag — is setting this line's price.
    /// The screen says so where it happens, because "why is 8 lb $33.75" is a
    /// question best answered before it is asked.
    static func minimumApplies(_ item: ServiceItem, entered: Double) -> Bool {
        entered > 0 && billableUnits(item, entered: entered) > entered
    }
}
