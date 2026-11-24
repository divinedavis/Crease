import CoreGraphics
import Foundation
import Testing
@testable import Crease

/// Home's search bar rises into the address field's place before the address
/// screen opens around it ("Part", owner, 2026-11-23). It has to know where
/// that field is, and the address screen has to know it was landed on.
@MainActor
struct SearchFlightTests {
    private func fresh() -> SearchFlight {
        let suite = "SearchFlightTests-\(UUID().uuidString)"
        return SearchFlight(defaults: UserDefaults(suiteName: suite)!)
    }

    private let bar = CGRect(x: 20, y: 547, width: 362, height: 56)

    @Test func theFirstFlightLandsBelowTheNavigationBarAndSteps() {
        let field = fresh().fieldFrame(below: bar, contentTop: 116)
        #expect(field.minY == 168, "measured on a 17 Pro: content top 116, field 168")
        #expect(field.minX == bar.minX && field.width == bar.width, "rises straight up")
        #expect(field.height == SearchFlight.fieldHeight)
    }

    @Test func laterFlightsLandOnTheMeasuredField() {
        let flight = fresh()
        let measured = CGRect(x: 20, y: 181.5, width: 362, height: 64)
        flight.rememberField(measured)
        #expect(flight.fieldFrame(below: bar, contentTop: 116) == measured)
    }

    @Test func anEmptyMeasurementIsIgnored() {
        let flight = fresh()
        flight.rememberField(.zero)
        #expect(flight.fieldFrame(below: bar, contentTop: 116).minY == 168)
    }

    @Test func onlyAJustLandedBarCountsAsAFlight() {
        let flight = fresh()
        #expect(!flight.landedRecently, "a service tile or Back opens the screen with its own rise")
        flight.landedAt = .now
        #expect(flight.landedRecently)
        flight.landedAt = Date.now.addingTimeInterval(-2)
        #expect(!flight.landedRecently)
    }
}
