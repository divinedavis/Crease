import CoreLocation
import Contacts
import MapKit
import XCTest
@testable import Crease

/// The street the order carries has to be the street under the pin.
///
/// Moving the pin used to change only the coordinate, so an order could say
/// "251 Dekalb Ave" while the courier was routed to Williamsburg. These pin
/// down what the pin screen hands back after a reverse geocode.
final class PinAddressTests: XCTestCase {

    private let dekalb = ResolvedAddress(
        line1: "251 Dekalb Ave", city: "Brooklyn", state: "NY", postalCode: "11205",
        coordinate: CLLocationCoordinate2D(latitude: 40.6896, longitude: -73.9692)
    )
    private let fulton = CLLocationCoordinate2D(latitude: 40.6829, longitude: -73.9656)

    private func placemark(number: String?, street: String?, zip: String? = "11238") -> CLPlacemark {
        let postal = CNMutablePostalAddress()
        postal.street = [number, street].compactMap { $0 }.joined(separator: " ")
        postal.city = "Brooklyn"
        postal.state = "NY"
        postal.postalCode = zip ?? ""
        return MKPlacemark(coordinate: fulton, postalAddress: postal)
    }

    func testTheStreetFollowsThePin() {
        let found = ResolvedAddress.underPin(
            placemark(number: "909", street: "Fulton St"), at: fulton, fallback: dekalb)
        XCTAssertEqual(found.city, "Brooklyn")
        XCTAssertEqual(found.coordinate.latitude, fulton.latitude)
        XCTAssertTrue(found.line1.contains("Fulton"), "got \(found.line1)")
        XCTAssertNotEqual(found, dekalb)
    }

    func testNoLookupKeepsTheOpeningStreetAtTheNewPoint() {
        let kept = ResolvedAddress.underPin(nil, at: fulton, fallback: dekalb)
        XCTAssertEqual(kept, dekalb)
        XCTAssertEqual(kept.coordinate.latitude, fulton.latitude,
                       "the pin the customer placed still wins over the street's old point")
    }

    func testAPinPointIgnoresCameraNoise() {
        let a = CLLocationCoordinate2D(latitude: 40.689600001, longitude: -73.969200001)
        XCTAssertEqual(PinPoint(a), PinPoint(dekalb.coordinate))
        XCTAssertNotEqual(PinPoint(fulton), PinPoint(dekalb.coordinate))
    }
}
