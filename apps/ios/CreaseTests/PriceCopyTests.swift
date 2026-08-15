import XCTest
@testable import Crease

/// An unpriced order must not show a price.
///
/// Nobody can cost a bag before opening it, so booking writes
/// `estimate_subtotal_cents = 0` and it stays zero until intake counts. Passed
/// straight to a currency formatter, that zero put "$0.00 est." on every open
/// order — a quote of free, on the one part of the bill Crease does not set.
final class PriceCopyTests: XCTestCase {

    private func order(
        estimate: Int = 0,
        subtotal: Int? = nil,
        total: Int? = nil
    ) -> Order {
        Order(
            id: UUID(),
            shortCode: "CR-TEST",
            status: .atCleaner,
            serviceTier: "round_trip",
            estimateSubtotalCents: estimate,
            subtotalCents: subtotal,
            totalCents: total,
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
            deliveryLegs: nil
        )
    }

    func testABookingCarriesNoPriceUntilTheShopCounts() {
        let booked = order()
        XCTAssertFalse(booked.hasPrice)
        XCTAssertNil(booked.priceText, "$0.00 is a quote; there is no quote yet")
    }

    func testACountedOrderShowsWhatTheShopCounted() {
        XCTAssertEqual(order(subtotal: 2200).priceText, 2200.asMoney)
        XCTAssertEqual(order(subtotal: 2200, total: 2450).priceText, 2450.asMoney,
                       "the charged total wins over the pre-approval subtotal")
    }

    /// A tier that does carry an estimate keeps showing it, marked as one.
    func testAnEstimateIsStillAnEstimate() {
        let quoted = order(estimate: 1800)
        XCTAssertEqual(quoted.priceText, 1800.asMoney)
        XCTAssertTrue(quoted.isEstimate)
        XCTAssertFalse(order(estimate: 1800, subtotal: 2200).isEstimate)
    }

    /// The approval screen has to name the line the count crossed. With no
    /// estimate, "above your $0.00 estimate" is both wrong and nonsense — the
    /// line is the hold, which is what the server compares against before it
    /// refuses to capture.
    func testTheApprovalReasonNamesWhateverTheCountActuallyExceeded() {
        XCTAssertEqual(order(estimate: 1800, subtotal: 2200).overageReason,
                       "above your \(1800.asMoney) estimate.")
        XCTAssertEqual(order(subtotal: 2200).overageReason,
                       "above the amount held on your card.")
    }
}
