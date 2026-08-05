import XCTest
@testable import Crease

/// Guards the two things the detail screen says once the bag is at the shop:
/// when it will be ready, and how to reach the people holding it.
///
/// Both replaced something that was technically true and useless — a pickup
/// window that had already happened, and an instruction to call a shop whose
/// number was nowhere on the screen.
final class ReadyEstimateTests: XCTestCase {

    private func order(
        status: OrderStatus,
        estimatedReadyAt: Date? = nil,
        readyAt: Date? = nil,
        cleaner: Cleaner? = nil
    ) -> Order {
        Order(
            id: UUID(),
            shortCode: "CR-TEST",
            status: status,
            serviceTier: "round_trip",
            estimateSubtotalCents: 0,
            subtotalCents: nil,
            totalCents: nil,
            deliveryFeeCents: 1499,
            serviceFeeCents: 0,
            pickupWindowStart: Date(),
            pickupWindowEnd: Date(),
            returnWindowStart: nil,
            returnWindowEnd: nil,
            estimatedReadyAt: estimatedReadyAt,
            readyAt: readyAt,
            customerNotes: nil,
            cleanerNotes: nil,
            createdAt: Date(),
            cleaner: cleaner,
            address: nil,
            orderItems: nil,
            deliveryLegs: nil
        )
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private var readsAmericanTimes: Bool {
        Locale.current.identifier.hasPrefix("en_US")
    }

    /// iOS separates the time from AM/PM with a narrow no-break space, not the
    /// space anyone types. Compared raw, these assertions fail against strings
    /// that are identical on screen and identical in the failure message.
    private func plainSpaces(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testTheEstimateRendersAsAThirtyMinuteBandEitherSide() throws {
        try XCTSkipUnless(readsAmericanTimes, "the expected string is en_US wording")

        let order = order(status: .atCleaner, estimatedReadyAt: date(8, 7, 18, 20))
        XCTAssertEqual(plainSpaces(order.readyWindowText), "Aug 7, ~5:50 – 6:50 PM")
    }

    /// The shortened form drops the marker on the first time because both ends
    /// share it. When they do not, dropping it says 11:50 in the wrong half of
    /// the day — a window that appears to run backwards.
    func testAWindowThatCrossesNoonKeepsBothMarkers() throws {
        try XCTSkipUnless(readsAmericanTimes, "the expected string is en_US wording")

        let order = order(status: .cleaning, estimatedReadyAt: date(8, 7, 12, 0))
        XCTAssertEqual(plainSpaces(order.readyWindowText), "Aug 7, ~11:30 AM – 12:30 PM")
    }

    func testAWindowThatCrossesMidnightNamesBothDays() throws {
        try XCTSkipUnless(readsAmericanTimes, "the expected string is en_US wording")

        let order = order(status: .cleaning, estimatedReadyAt: date(8, 7, 0, 10))
        XCTAssertEqual(plainSpaces(order.readyWindowText), "Aug 6, ~11:40 PM – Aug 7, 12:40 AM")
    }

    /// The server's number is the one the shop is working to. Inventing one on
    /// the phone from a booking time and a default turnaround would disagree
    /// with it the moment intake recounts the bag.
    func testNoEstimateShowsNothingRatherThanAGuess() {
        let order = order(status: .atCleaner, estimatedReadyAt: nil)
        XCTAssertNil(order.readyWindowText)
        XCTAssertFalse(order.showsReadyEstimate)
    }

    func testThePickupWindowGivesWayToTheEstimateAtTheShopCounter() {
        let estimate = date(8, 7, 18, 20)

        for status in [OrderStatus.scheduled, .pickupDispatched, .inTransitToCleaner] {
            XCTAssertFalse(
                order(status: status, estimatedReadyAt: estimate).hasReachedCleaner,
                "\(status.rawValue): a driver is still coming, so the pickup window is the live one"
            )
        }
        for status in [OrderStatus.atCleaner, .awaitingApproval, .cleaning] {
            let order = order(status: status, estimatedReadyAt: estimate)
            XCTAssertTrue(order.hasReachedCleaner, "\(status.rawValue): that window has already happened")
            XCTAssertTrue(order.showsReadyEstimate, "\(status.rawValue) should answer 'when is it done'")
        }

        // Finished is a fact, not an estimate. Leaving the promise on screen
        // next to the delivery the customer is now scheduling is one number too
        // many, and the stale one.
        XCTAssertFalse(
            order(status: .ready, estimatedReadyAt: estimate, readyAt: date(8, 7, 18, 5)).showsReadyEstimate
        )
    }

    func testAShopsNumberIsShownAsPeopleReadItAndDialsAsTyped() {
        let shop = Cleaner(
            id: UUID(), name: "Bedford Cleaners", phone: "+15555550199",
            line1: nil, city: "Brooklyn", state: "NY",
            turnaroundHours: 48, lat: nil, lng: nil
        )
        XCTAssertEqual(shop.formattedPhone, "(555) 555-0199")
        XCTAssertEqual(shop.callURL?.absoluteString, "tel:+15555550199")
    }

    /// A shop with no number on file drops the call affordance entirely. A
    /// `tel:` link built from nothing opens an empty dialer, which reads as the
    /// tap having failed.
    func testAMissingOrUnusableNumberOffersNothingToTap() {
        func shop(phone: String?) -> Cleaner {
            Cleaner(
                id: UUID(), name: "Nameless", phone: phone,
                line1: nil, city: "Brooklyn", state: "NY",
                turnaroundHours: 48, lat: nil, lng: nil
            )
        }
        XCTAssertNil(shop(phone: nil).callURL)
        XCTAssertNil(shop(phone: nil).formattedPhone)
        XCTAssertNil(shop(phone: "555-01").callURL)
    }
}
