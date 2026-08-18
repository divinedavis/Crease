import XCTest
@testable import Crease

/// The phone and the counter have to reach the same number.
///
/// These are the cases from apps/portal/lib/pricing.test.ts, run against the
/// Swift side. Two implementations of one price sheet is a liability — the app
/// quotes an estimate, the shop's till produces a total, and any disagreement
/// between them reads to the customer as a shop overcharging. If a case here
/// is changed, change it there in the same commit.
final class ServicePricingTests: XCTestCase {

    private let wash = ServiceItem(
        id: UUID(), code: "wash_fold", label: "Wash & fold",
        unitPriceCents: 225, serviceType: "wash_fold", unit: "pound", minimumUnits: 15
    )
    private let shirt = ServiceItem(
        id: UUID(), code: "shirt", label: "Laundered shirt",
        unitPriceCents: 349, serviceType: "dry_clean", unit: "piece", minimumUnits: 0
    )

    func testAScaleReadingIsBilledToThePoundNotRoundedDown() {
        XCTAssertEqual(ServicePricing.lineTotalCents(wash, entered: 17.4), 3915)
        XCTAssertNotEqual(
            ServicePricing.lineTotalCents(wash, entered: 17.4),
            ServicePricing.lineTotalCents(wash, entered: 17)
        )
    }

    func testUnderTheMinimumBillsTheMinimum() {
        XCTAssertEqual(ServicePricing.billableUnits(wash, entered: 12), 15)
        XCTAssertEqual(ServicePricing.lineTotalCents(wash, entered: 12), 3375)
        XCTAssertTrue(ServicePricing.minimumApplies(wash, entered: 12),
                      "the screen has to say why 12 lb costs what 15 lb costs")
    }

    func testOverTheMinimumBillsTheRealWeight() {
        XCTAssertEqual(ServicePricing.billableUnits(wash, entered: 22.5), 22.5)
        XCTAssertEqual(ServicePricing.lineTotalCents(wash, entered: 22.5), 5063)
        XCTAssertFalse(ServicePricing.minimumApplies(wash, entered: 22.5))
    }

    func testABlankLineStaysBlankRatherThanBecomingAMinimumCharge() {
        // Lifting zero to the floor would invent a fifteen pound order nobody
        // handed over — and put it on the booking screen as a price.
        XCTAssertEqual(ServicePricing.billableUnits(wash, entered: 0), 0)
        XCTAssertEqual(ServicePricing.lineTotalCents(wash, entered: 0), 0)
        XCTAssertFalse(ServicePricing.minimumApplies(wash, entered: 0))
    }

    func testPerPieceServicesAreUnaffectedByTheMinimumMachinery() {
        XCTAssertEqual(ServicePricing.lineTotalCents(shirt, entered: 3), 1047)
        XCTAssertEqual(ServicePricing.lineTotalCents(shirt, entered: 0), 0)
    }

    func testTheTotalEqualsTheVisibleLinesAddedUp() {
        // Rounding once at the end gives 5484 here. Both lines are on screen,
        // so the sum has to match what the customer can check by hand.
        let lines = [(item: wash, entered: 17.4), (item: shirt, entered: 4.5)]
        XCTAssertEqual(ServicePricing.subtotalCents(lines), 3915 + 1571)
    }

    func testGarbageInputCannotBecomeACharge() {
        XCTAssertEqual(ServicePricing.billableUnits(wash, entered: .nan), 0)
        XCTAssertEqual(ServicePricing.billableUnits(wash, entered: -5), 0)
        XCTAssertEqual(ServicePricing.billableUnits(wash, entered: .infinity), 0)
    }
}

/// The hold, which the customer meets twice: once in our own words and once on
/// Stripe's Pay button. The two have to be the same number, and both have to
/// match holdForOrder in packages/payments/src/types.ts.
extension ServicePricingTests {

    func testHeadroomSitsOnTheCleaningNeverOnTheFee() {
        // A $22.48 bag with a $16.95 courier held $49.29 when the buffer ran
        // over the combined figure. Nearly four dollars of that was headroom
        // on a fee the dispatcher had already pinned.
        XCTAssertEqual(ServicePricing.holdCents(cleaningCents: 2248, fixedCents: 1695), 2248 + 1695 + 562)
    }

    func testTheCapStillBindsOnABigBag() {
        // 25% of $200 is $50, and we never hold more than we would charge
        // without asking.
        XCTAssertEqual(ServicePricing.holdCents(cleaningCents: 20000, fixedCents: 2995), 20000 + 2995 + 1500)
    }

    func testAnUnpricedBagGetsTheFlatRoomRatherThanNone() {
        XCTAssertEqual(ServicePricing.holdCents(cleaningCents: 0, fixedCents: 1695), 1695 + 1500)
    }

    func testAHoldNeverDipsUnderWhatIsAlreadyCommitted() {
        for cleaning in [0, 1, 500, 2248, 9999, 20000] {
            XCTAssertGreaterThanOrEqual(
                ServicePricing.holdCents(cleaningCents: cleaning, fixedCents: 1695),
                cleaning + 1695
            )
        }
    }
}
