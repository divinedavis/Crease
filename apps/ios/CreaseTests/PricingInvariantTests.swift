import Foundation
import Testing
@testable import Crease

/// Swift Testing (Apple's framework for new unit tests since Xcode 16), added
/// 2026-10-03 beside the XCTest suites. Each argument runs as its own case, so
/// a failure names the weight or the number that broke.
///
/// These are properties of the price sheet rather than single examples: the
/// examples live in ServicePricingTests (mirrored from the portal's tests);
/// these say what must hold for ANY reading the scale or the customer gives.
@Suite("Price sheet invariants")
struct PricingInvariantTests {
    private static let wash = ServiceItem(
        id: UUID(), code: "wash_fold", label: "Wash & fold",
        unitPriceCents: 225, serviceType: "wash_fold", unit: "pound", minimumUnits: 15
    )
    private static let shirt = ServiceItem(
        id: UUID(), code: "shirt", label: "Laundered shirt",
        unitPriceCents: 349, serviceType: "dry_clean", unit: "piece", minimumUnits: 0
    )

    /// A heavier bag never costs less than a lighter one.
    @Test("price never drops as the bag gets heavier", arguments: [0.5, 5, 14.9, 15, 15.1, 22.5, 40])
    func monotonic(_ pounds: Double) {
        let here = ServicePricing.lineTotalCents(Self.wash, entered: pounds)
        let more = ServicePricing.lineTotalCents(Self.wash, entered: pounds + 0.1)
        #expect(more >= here)
    }

    /// Anything on the scale bills at least the shop's minimum; nothing bills nothing.
    @Test("a weighed line bills zero or at least the minimum", arguments: [0.0, 0.1, 3, 14.99, 15, 30])
    func minimumFloor(_ pounds: Double) {
        let cents = ServicePricing.lineTotalCents(Self.wash, entered: pounds)
        if pounds == 0 { #expect(cents == 0) } else { #expect(cents >= 15 * 225) }
    }

    /// Per-piece lines are plain multiplication — no minimum machinery.
    @Test("per-piece lines are count x price", arguments: 0...6)
    func perPiece(_ count: Int) {
        #expect(ServicePricing.lineTotalCents(Self.shirt, entered: Double(count)) == count * 349)
    }
}

@Suite("Phone numbers")
struct PhoneNumberInvariantTests {
    @Test("every US shape formats the same", arguments: ["+17185550142", "7185550142", "(718) 555-0142",
                                                         "718-555-0142", "718.555.0142", "1 718 555 0142"])
    func usShapes(_ raw: String) {
        #expect(PhoneNumber.formatted(raw) == "(718) 555-0142")
    }

    /// A dial URL is only offered when it carries a whole number.
    @Test("short or empty numbers are never dialable", arguments: ["", "555-0142", "12345", "+1"])
    func notDialable(_ raw: String) {
        #expect(PhoneNumber.callURL(raw) == nil)
    }
}

@Suite("Amounts read aloud")
struct SpokenMoneyTests {
    /// VoiceOver hears words, not "$22.00" (OrderDetailView.spoken).
    @Test(arguments: [(2200, "22 dollars"), (100, "1 dollar"), (2250, "22 dollars 50 cents"), (101, "1 dollar 1 cent"), (0, "0 dollars")])
    func spoken(_ cents: Int, _ expected: String) {
        #expect(OrderDetailView.spoken(cents) == expected)
    }
}
