import XCTest
@testable import Crease

/// Guards the status → progress-step mapping.
///
/// This was wrong once already: `atCleaner` pointed at the "Cleaning" step, so
/// the app told customers their clothes were being cleaned while the shop had
/// not yet opened the bag. It renders as a plausible-looking track, so nothing
/// about it looks broken on screen — only an explicit assertion catches it.
final class JourneyTrackTests: XCTestCase {

    private let steps = ["Pickup", "At cleaner", "Cleaning", "Return"]

    func testEachStatusPointsAtTheStepItActuallyDescribes() {
        let expected: [(OrderStatus, String)] = [
            (.scheduled, "Pickup"),
            // Still in a car, not at the shop.
            (.pickupDispatched, "Pickup"),
            (.inTransitToCleaner, "Pickup"),
            // Arrived, but nobody has counted it yet.
            (.atCleaner, "At cleaner"),
            (.awaitingApproval, "At cleaner"),
            (.cleaning, "Cleaning"),
            (.ready, "Return"),
            (.returnDispatched, "Return"),
            (.inTransitToCustomer, "Return"),
        ]

        for (status, stepName) in expected {
            guard let index = status.stepIndex else {
                XCTFail("\(status.rawValue) should sit on the track")
                continue
            }
            XCTAssertEqual(
                steps[index], stepName,
                "\(status.rawValue) lit '\(steps[index])', expected '\(stepName)'"
            )
        }
    }

    func testTerminalStatusesSitOutsideTheTrack() {
        XCTAssertNil(OrderStatus.cancelled.stepIndex)
        XCTAssertNil(OrderStatus.failed.stepIndex)
        XCTAssertEqual(OrderStatus.delivered.stepIndex, steps.count)
    }

    func testProgressNeverGoesBackwardsThroughTheHappyPath() {
        // The order a real order actually moves through.
        let happyPath: [OrderStatus] = [
            .scheduled, .pickupDispatched, .inTransitToCleaner, .atCleaner,
            .cleaning, .ready, .returnDispatched, .inTransitToCustomer, .delivered,
        ]
        let indexes = happyPath.compactMap(\.stepIndex)
        XCTAssertEqual(indexes.count, happyPath.count)
        for (a, b) in zip(indexes, indexes.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "progress moved backwards")
        }
    }

    func testActiveAndTerminalClassification() {
        XCTAssertTrue(OrderStatus.cleaning.isActive)
        XCTAssertFalse(OrderStatus.delivered.isActive)
        XCTAssertFalse(OrderStatus.cancelled.isActive)
    }

    /// A failed order is paid and stranded, not finished.
    ///
    /// It reaches that status when the fee has been taken and no courier would
    /// accept the job. Classifying it as terminal filed it under Past orders
    /// with the delivered ones, so the customer was charged for a pickup that
    /// never happened and had nowhere to see it, let alone get the money back.
    func testAFailedOrderStaysVisibleAndCancellable() {
        XCTAssertTrue(OrderStatus.failed.isActive)
        XCTAssertTrue(OrderStatus.failed.isCancellable)
    }
}
