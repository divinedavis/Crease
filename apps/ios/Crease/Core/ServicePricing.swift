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

    /// The count a line starts at once it is in the bag at all.
    ///
    /// The shop's own floor, where it has one. Under a 10 lb minimum every
    /// weight bills the same $20, so a stepper starting at zero spends its
    /// first nine taps moving a number that changes no price — and a line left
    /// at a dash asks every customer to find the floor in the small print and
    /// dial it in by hand, on every order. The floor is the only opening value
    /// that is both honest about the bill and useful as a place to start.
    static func startingUnits(_ item: ServiceItem) -> Double {
        item.minimumUnits > 0 ? item.minimumUnits : 1
    }

    /// The line to open at the shop's floor, when there is exactly one to open.
    ///
    /// Two guards, both about not putting things in somebody's bag:
    ///
    /// - only when nothing is counted anywhere, so tapping another service tab
    ///   to see what it costs never fills the bag (that clash is the conflict
    ///   banner's whole subject, and it must not be one this screen invented);
    /// - only when the service has one weighed line, because with two the floor
    ///   is not one number and prefilling both books two bags nobody asked for.
    static func lineToOpenAtMinimum(
        menu: [ServiceItem],
        serviceType: String,
        entered: [UUID: Double]
    ) -> ServiceItem? {
        guard menu.allSatisfy({ (entered[$0.id] ?? 0) <= 0 }) else { return nil }
        let weighed = menu.filter {
            $0.serviceType == serviceType && $0.isByWeight && $0.minimumUnits > 0
        }
        guard weighed.count == 1 else { return nil }
        return weighed.first
    }

    /// Whether the weight floor — not the bag — is setting this line's price.
    /// The screen says so where it happens, because "why is 8 lb $33.75" is a
    /// question best answered before it is asked.
    static func minimumApplies(_ item: ServiceItem, entered: Double) -> Bool {
        entered > 0 && billableUnits(item, entered: entered) > entered
    }
}

/// The weight a customer last booked at a shop, so the next order opens there.
///
/// Most people send about the same bag every week. Opening at the shop's floor
/// every time made a regular 18 lb customer dial eight pounds back in on every
/// order. Keyed by the price-list line, which belongs to one shop, so a bag
/// size at one laundromat never lands on another's floor. Saved when the order
/// is created — what was booked, not whatever the stepper was left at.
enum LastBagSize {
    private static let prefix = "crease.lastBagPounds."

    static func pounds(for item: ServiceItem, in defaults: UserDefaults = .standard) -> Double? {
        let value = defaults.double(forKey: prefix + item.id.uuidString)
        return value > 0 ? value : nil
    }

    static func remember(
        _ quantities: [UUID: Double],
        menu: [ServiceItem],
        in defaults: UserDefaults = .standard
    ) {
        for item in menu where item.isByWeight {
            if let pounds = quantities[item.id], pounds > 0 {
                defaults.set(pounds, forKey: prefix + item.id.uuidString)
            }
        }
    }
}

extension ServicePricing {
    /// Where a weighed line opens: the last bag booked at this shop, or the
    /// shop's floor when there is none. Never under the floor — a remembered
    /// 8 lb from before a shop raised its minimum would only be billed as the
    /// minimum anyway — and never over the 200 lb the stepper allows.
    static func openingUnits(_ item: ServiceItem, in defaults: UserDefaults = .standard) -> Double {
        let floor = startingUnits(item)
        guard let last = LastBagSize.pounds(for: item, in: defaults) else { return floor }
        return min(max(last, floor), 200)
    }
}
