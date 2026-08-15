import XCTest
@testable import Crease

/// Guards the detail screen against describing a service the customer did not
/// buy.
///
/// Every one-leg order used to be labelled "Pickup & delivery" and drawn on a
/// track ending in "Return" — copy written for the round trip and left on the
/// two tiers that pay for a single leg. Order 9864CA was a real `pickup_only`
/// order promising a delivery nobody had bought.
final class ServiceTierCopyTests: XCTestCase {

    private func order(tier: String) -> Order {
        Order(
            id: UUID(),
            shortCode: "CR-TEST",
            status: .atCleaner,
            serviceTier: tier,
            estimateSubtotalCents: 0,
            subtotalCents: nil,
            totalCents: nil,
            deliveryFeeCents: 1995,
            serviceFeeCents: 0,
            pickupWindowStart: nil,
            pickupWindowEnd: nil,
            returnWindowStart: nil,
            returnWindowEnd: nil,
            estimatedReadyAt: nil,
            readyAt: nil,
            customerNotes: nil,
            cleanerNotes: nil,
            customerItemCount: nil,
            cleanerItemCount: nil,
            createdAt: Date(),
            cleaner: nil,
            address: nil,
            orderItems: nil,
            deliveryLegs: nil
        )
    }

    func testTheAddressIsLabelledWithTheLegsTheOrderPaidFor() {
        XCTAssertEqual(order(tier: "round_trip").addressLabel, "Pickup & delivery")
        XCTAssertEqual(order(tier: "pickup_only").addressLabel, "Pickup address")
        XCTAssertEqual(order(tier: "return_only").addressLabel, "Delivery address")
    }

    /// The ends of the track are the tier: only a round trip has a courier at
    /// both of them.
    func testTheJourneyTrackEndsWhereTheTierEnds() {
        XCTAssertEqual(order(tier: "round_trip").journeySteps,
                       ["Pickup", "At cleaner", "Cleaning", "Return"])
        XCTAssertEqual(order(tier: "pickup_only").journeySteps,
                       ["Pickup", "At cleaner", "Cleaning", "Collect"])
        XCTAssertEqual(order(tier: "return_only").journeySteps,
                       ["Drop off", "At cleaner", "Cleaning", "Return"])
    }

    /// Read back from the booking screen's own list, so renaming a tier there
    /// cannot leave the detail screen calling it something else.
    func testTheTierIsNamedAsTheBookingScreenNamedIt() {
        for option in ServiceOption.all {
            XCTAssertEqual(order(tier: option.id).serviceTierName, option.name)
        }
    }

    /// A tier the app has not shipped yet still has to read as words. The
    /// fallback is what a future server-side tier looks like until the app
    /// catches up.
    func testAnUnknownTierDegradesToReadableWords() {
        XCTAssertEqual(order(tier: "express_round_trip").serviceTierName, "Express Round Trip")
        XCTAssertEqual(order(tier: "express_round_trip").addressLabel, "Pickup & delivery")
    }
}
