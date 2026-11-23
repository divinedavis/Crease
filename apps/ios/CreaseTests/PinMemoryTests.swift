import CoreLocation
import Foundation
import Testing
@testable import Crease

/// An address used before opens its pin where the customer put it last time
/// (owner, 2026-11-22), but never at a remembered point far from the door.
struct PinMemoryTests {
    private let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: "PinMemoryTests-\(UUID().uuidString)")!
        return d
    }()

    private let geocoded = ResolvedAddress(
        line1: "296 Vanderbilt Ave", city: "Brooklyn", state: "NY", postalCode: "11205",
        coordinate: CLLocationCoordinate2D(latitude: 40.68860, longitude: -73.96870)
    )
    /// The side door, about 40 m from the geocode.
    private let sideDoor = CLLocationCoordinate2D(latitude: 40.68895, longitude: -73.96880)

    @Test func theSameDoorIsOneKeyWhateverTheSpacingOrCase() {
        #expect(PinMemory.addressKey(line1: "296  Vanderbilt Ave ", postalCode: "11205-1234")
                == PinMemory.addressKey(line1: "296 vanderbilt ave", postalCode: "11205"))
    }

    @Test func aPinConfirmedBeforeIsWhereItOpens() {
        PinMemory.remember(geocoded, at: sideDoor, defaults: defaults)
        let opened = PinMemory.applied(to: geocoded, saved: [], defaults: defaults)
        #expect(opened.coordinate.latitude == sideDoor.latitude)
        #expect(opened.coordinate.longitude == sideDoor.longitude)
    }

    @Test func aSavedAddressOutranksThisPhonesMemory() {
        PinMemory.remember(geocoded, at: sideDoor, defaults: defaults)
        let serverPoint = CLLocationCoordinate2D(latitude: 40.68840, longitude: -73.96860)
        let opened = PinMemory.applied(
            to: geocoded,
            saved: [(line1: "296 Vanderbilt Ave", postalCode: "11205", coordinate: serverPoint)],
            defaults: defaults
        )
        #expect(opened.coordinate.latitude == serverPoint.latitude)
    }

    @Test func aRememberedPointFarFromTheDoorIsIgnored() {
        // The Brooklyn fallback that early saved rows carried, ~3 km away.
        let fallback = CLLocationCoordinate2D(latitude: 40.7178, longitude: -73.9569)
        let opened = PinMemory.applied(
            to: geocoded,
            saved: [(line1: "296 Vanderbilt Ave", postalCode: "11205", coordinate: fallback)],
            defaults: defaults
        )
        #expect(opened.coordinate.latitude == geocoded.coordinate.latitude)
    }

    @Test func anAddressNeverUsedKeepsItsGeocode() {
        let opened = PinMemory.applied(to: geocoded, saved: [], defaults: defaults)
        #expect(opened == geocoded)
        #expect(opened.coordinate.latitude == geocoded.coordinate.latitude)
    }
}
