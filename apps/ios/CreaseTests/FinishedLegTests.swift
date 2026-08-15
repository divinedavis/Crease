import XCTest
@testable import Crease

/// A delivery that happened has to leave a mark on the screen.
///
/// The courier card only ever describes the *live* leg, so the instant a
/// driver finished, everything about them disappeared: order 2232C4 had a
/// pickup leg driven to `delivered`, and the detail screen said nothing about
/// it except one more green segment on the track.
final class FinishedLegTests: XCTestCase {

    private func leg(
        _ which: String,
        status: String,
        pickedUpAt: Date? = nil,
        completedAt: Date? = nil
    ) -> DeliveryLeg {
        DeliveryLeg(
            id: UUID(),
            leg: which,
            status: status,
            provider: "mock",
            courierName: "Marcus T.",
            courierVehicle: "Toyota Camry",
            trackingUrl: nil,
            dropoffPincode: nil,
            pickedUpAt: pickedUpAt,
            completedAt: completedAt
        )
    }

    private func order(legs: [DeliveryLeg]?) -> Order {
        Order(
            id: UUID(),
            shortCode: "CR-TEST",
            status: .atCleaner,
            serviceTier: "round_trip",
            estimateSubtotalCents: 0,
            subtotalCents: nil,
            totalCents: nil,
            deliveryFeeCents: 2995,
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
            deliveryLegs: legs
        )
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 8, day: 8, hour: hour, minute: minute)
        )!
    }

    func testAFinishedLegIsTheOneTheCourierCardStoppedShowing() {
        let done = leg("pickup", status: "delivered", completedAt: date(13, 41))
        let live = leg("return", status: "en_route_to_pickup")
        let order = order(legs: [done, live])

        XCTAssertEqual(order.liveLeg?.id, live.id)
        XCTAssertEqual(order.finishedLegs.map(\.id), [done.id],
                       "the live leg is still happening; it belongs to the courier card")
    }

    /// A round trip reads top to bottom, so the pickup that ended this morning
    /// must not sit under the delivery that ended this afternoon.
    func testFinishedLegsAreOrderedByWhenTheyEnded() {
        let ret = leg("return", status: "delivered", completedAt: date(17, 2))
        let pickup = leg("pickup", status: "delivered", completedAt: date(13, 41))
        XCTAssertEqual(
            order(legs: [ret, pickup]).finishedLegs.map(\.leg),
            ["pickup", "return"]
        )
    }

    /// `returned` is over, and it is not a success: the clothes are back at the
    /// shop. Anything that treats "finished" as "delivered" tells the customer
    /// their order arrived when it is sitting on a counter across town.
    func testAReturnedLegIsFinishedButNotDelivered() {
        let bounced = leg("return", status: "returned", completedAt: date(17, 2))
        XCTAssertFalse(bounced.isLive)
        XCTAssertFalse(bounced.didDeliver)
        XCTAssertTrue(leg("pickup", status: "delivered").didDeliver)
    }

    func testAnOrderWithNoLegsHasNothingToReport() {
        XCTAssertTrue(order(legs: nil).finishedLegs.isEmpty)
        XCTAssertTrue(order(legs: []).finishedLegs.isEmpty)
    }
}
