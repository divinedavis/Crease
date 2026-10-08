import CoreLocation
import XCTest
@testable import Crease

/// The pieces of the ride-hailing redesign (2026-10-08) that are logic rather
/// than layout: the route the booking map draws in, and Rebook.
final class RideLayoutTests: XCTestCase {
    private let door = CLLocationCoordinate2D(latitude: 40.6890, longitude: -73.9650)
    private let shop = CLLocationCoordinate2D(latitude: 40.6830, longitude: -73.9560)

    func testAStraightRouteIsSplitIntoEvenSteps() {
        let path = RoutePath.densified([door, shop], minimum: 40)
        XCTAssertGreaterThanOrEqual(path.count, 41, "two points must become enough to draw smoothly")
        XCTAssertEqual(path.first?.latitude, door.latitude)
        XCTAssertEqual(path.last!.latitude, shop.latitude, accuracy: 1e-9)
        XCTAssertEqual(path.last!.longitude, shop.longitude, accuracy: 1e-9)
    }

    func testARouteKeepsEveryTurn() {
        let corner = CLLocationCoordinate2D(latitude: door.latitude, longitude: shop.longitude)
        let path = RoutePath.densified([door, corner, shop], minimum: 10)
        XCTAssertTrue(path.contains { abs($0.latitude - corner.latitude) < 1e-9 && abs($0.longitude - corner.longitude) < 1e-9 },
                      "densifying must not cut the corner the directions turned at")
    }

    func testDegenerateRoutesComeBackAsGiven() {
        XCTAssertEqual(RoutePath.densified([door]).count, 1)
        XCTAssertEqual(RoutePath.densified([door, door]).count, 2)
    }

    private let cleaner = Cleaner(id: UUID(), name: "Fulton Cleaners", phone: nil, line1: nil,
                                  city: "Brooklyn", state: "NY", turnaroundHours: 48, lat: nil, lng: nil)

    private func order(address: Address?, items: [OrderItem]?) -> Order {
        Order(
            id: UUID(), shortCode: "CR", status: .delivered, serviceTier: "round_trip",
            estimateSubtotalCents: 2000, subtotalCents: nil, totalCents: nil,
            deliveryFeeCents: 2995, serviceFeeCents: 0,
            pickupWindowStart: Date(), pickupWindowEnd: Date(),
            returnWindowStart: nil, returnWindowEnd: nil, estimatedReadyAt: nil, readyAt: nil,
            customerNotes: nil, cleanerNotes: nil, customerItemCount: nil, cleanerItemCount: nil,
            createdAt: Date(), cleaner: cleaner, address: address,
            orderItems: items, deliveryLegs: nil
        )
    }

    func testRebookCarriesTheShopAndTheBag() throws {
        let address = try XCTUnwrap(RideLayoutTests.address())
        let items = [
            OrderItem(id: UUID(), label: "Shirt", quantity: 3, unitPriceCents: 349),
            OrderItem(id: UUID(), label: "Shirt", quantity: 1, unitPriceCents: 349),
            OrderItem(id: UUID(), label: "Suit", quantity: 1, unitPriceCents: 1599),
        ]
        let usual = try XCTUnwrap(UsualOrder.rebook(order(address: address, items: items)))
        XCTAssertEqual(usual.cleanerId, cleaner.id)
        XCTAssertEqual(usual.address.id, address.id)
        XCTAssertEqual(usual.lines["Shirt"], 4, "repeated lines are summed")
        XCTAssertEqual(usual.lines["Suit"], 1)
    }

    func testRebookNeedsSomethingToRepeat() throws {
        let address = try XCTUnwrap(RideLayoutTests.address())
        XCTAssertNil(UsualOrder.rebook(order(address: address, items: [])))
        XCTAssertNil(UsualOrder.rebook(order(address: address, items: nil)))
        XCTAssertNil(UsualOrder.rebook(order(address: nil, items: [OrderItem(id: UUID(), label: "Shirt", quantity: 1, unitPriceCents: 349)])))
    }

    /// Decoded the way the store gets it, so the test does not depend on the
    /// shape of Address's memberwise initialiser.
    private static func address() -> Address? {
        let json = """
        {"id":"\(UUID().uuidString)","user_id":"\(UUID().uuidString)","label":"Home","line1":"251 DeKalb Ave",
         "city":"Brooklyn","state":"NY","postal_code":"11205","lat":40.6890,"lng":-73.9650}
        """
        return try? JSONDecoder().decode(Address.self, from: Data(json.utf8))
    }
}
