import CoreLocation
import Foundation
import Testing
@testable import Crease

/// A saved address with no point, or with the Brooklyn stand-in, is not a
/// door (owner, 2026-11-22: the founder's Home row measured trips from
/// Williamsburg). Such rows are geocoded and confirmed on the map instead.
struct SavedPointTests {
    private func address(lat: Double?, lng: Double?) -> Address {
        Address(id: UUID(), label: "Home", line1: "251 Dekalb Ave", line2: nil, city: "Brooklyn",
                state: "NY", postalCode: "11205", accessNotes: nil, lat: lat, lng: lng)
    }

    @Test func theBrooklynStandInIsNotAKnownPoint() {
        #expect(address(lat: 40.7178, lng: -73.9569).knownCoordinate == nil)
        #expect(address(lat: 40.71781, lng: -73.95691).knownCoordinate == nil)
    }

    @Test func aMissingPointIsNotAKnownPoint() {
        #expect(address(lat: nil, lng: nil).knownCoordinate == nil)
        #expect(address(lat: 40.6895, lng: nil).knownCoordinate == nil)
    }

    @Test func aRealPointIsKept() {
        let point = address(lat: 40.689524, lng: -73.969026).knownCoordinate
        #expect(point?.latitude == 40.689524)
        #expect(point?.longitude == -73.969026)
    }

    @Test func aResolvedAddressKnowsWhenItIsOnTheStandIn() {
        #expect(address(lat: nil, lng: nil).asResolved.isPlaceholderPoint)
        #expect(!address(lat: 40.689524, lng: -73.969026).asResolved.isPlaceholderPoint)
    }
}
