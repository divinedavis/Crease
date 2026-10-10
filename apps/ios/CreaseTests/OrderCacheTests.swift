import XCTest
@testable import Crease

/// The on-disk order list that lets home draw at launch: it must round-trip,
/// stay per customer, expire, and disappear on sign-out.
final class OrderCacheTests: XCTestCase {
    override func tearDown() { OrderCache.clearAll() }

    private let shop = Cleaner(id: UUID(), name: "Fulton Cleaners", phone: nil, line1: nil,
                               city: "Brooklyn", state: "NY", turnaroundHours: 48, lat: nil, lng: nil)

    private func order(_ status: OrderStatus, attention: Bool = false) -> Order {
        Order(
            id: UUID(), shortCode: "CR", status: attention ? .awaitingApproval : status, serviceTier: "round_trip",
            estimateSubtotalCents: 2000, subtotalCents: nil, totalCents: nil,
            deliveryFeeCents: 2995, serviceFeeCents: 0,
            pickupWindowStart: Date(), pickupWindowEnd: Date(),
            returnWindowStart: nil, returnWindowEnd: nil, estimatedReadyAt: nil, readyAt: nil,
            customerNotes: "Buzz 4B", cleanerNotes: nil, customerItemCount: nil, cleanerItemCount: nil,
            createdAt: Date(), cleaner: shop, address: nil,
            orderItems: [OrderItem(id: UUID(), label: "Wash & fold", quantity: 12, unitPriceCents: 200)],
            deliveryLegs: nil
        )
    }

    func testTheListRoundTripsForItsOwnCustomerOnly() {
        let me = UUID(), someoneElse = UUID()
        let saved = [order(.scheduled), order(.delivered)]
        OrderCache.save(OrderCache(orders: saved, cleaners: [shop], addresses: [], savedAt: Date()), for: me)

        let loaded = OrderCache.load(for: me)
        XCTAssertEqual(loaded?.orders.map(\.id), saved.map(\.id))
        XCTAssertEqual(loaded?.orders.first?.customerNotes, "Buzz 4B")
        XCTAssertEqual(loaded?.cleaners.first?.name, "Fulton Cleaners")
        XCTAssertNil(OrderCache.load(for: someoneElse), "another customer never sees this list")
    }

    func testAStaleListIsNotDrawn() {
        let me = UUID()
        OrderCache.save(OrderCache(orders: [order(.scheduled)], cleaners: [], addresses: [],
                                   savedAt: Date().addingTimeInterval(-8 * 86400)), for: me)
        XCTAssertNil(OrderCache.load(for: me))
    }

    func testSignOutWipesIt() {
        let me = UUID()
        OrderCache.save(OrderCache(orders: [order(.scheduled)], cleaners: [], addresses: [], savedAt: Date()), for: me)
        OrderCache.clearAll()
        XCTAssertNil(OrderCache.load(for: me))
    }

    func testActivitySectionsAreSplitInOnePass() {
        let waiting = order(.scheduled, attention: true)
        let moving = order(.scheduled)
        let done = order(.delivered)
        let lists = OrderLists([waiting, moving, done])
        XCTAssertEqual(lists.attention.map(\.id), [waiting.id])
        XCTAssertEqual(lists.active.map(\.id), [waiting.id, moving.id])
        XCTAssertEqual(lists.activeOther.map(\.id), [moving.id], "an order needing attention isn't listed twice")
        XCTAssertEqual(lists.past.map(\.id), [done.id])
    }
}
