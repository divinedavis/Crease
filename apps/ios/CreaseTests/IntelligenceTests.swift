import UIKit
import XCTest
@testable import Crease

/// The decisions behind the on-device tools: what a photo's labels, a care
/// label's words, a ticket's text and a typed sentence turn into on a shop's
/// own price list. The Apple frameworks produce the raw material; these pin
/// down what the app does with it.
final class IntelligenceTests: XCTestCase {

    private let shirt = ServiceItem(id: UUID(), code: "shirt", label: "Laundered shirt", unitPriceCents: 349, serviceType: "dry_clean", unit: "piece", minimumUnits: 0)
    private let pants = ServiceItem(id: UUID(), code: "pants", label: "Pants / slacks", unitPriceCents: 799, serviceType: "dry_clean", unit: "piece", minimumUnits: 0)
    private let suit = ServiceItem(id: UUID(), code: "suit_2pc", label: "Two-piece suit", unitPriceCents: 1899, serviceType: "dry_clean", unit: "piece", minimumUnits: 0)
    private let coat = ServiceItem(id: UUID(), code: "coat", label: "Overcoat", unitPriceCents: 2499, serviceType: "dry_clean", unit: "piece", minimumUnits: 0)
    private let dress = ServiceItem(id: UUID(), code: "dress", label: "Dress", unitPriceCents: 1599, serviceType: "dry_clean", unit: "piece", minimumUnits: 0)
    private let washFold = ServiceItem(id: UUID(), code: "wash_fold", label: "Wash & fold", unitPriceCents: 200, serviceType: "wash_fold", unit: "pound", minimumUnits: 10)
    private let comforter = ServiceItem(id: UUID(), code: "wash_fold_bedding", label: "Comforter / bedding", unitPriceCents: 3499, serviceType: "wash_fold", unit: "piece", minimumUnits: 0)

    private var menu: [ServiceItem] { [shirt, pants, suit, coat, dress, washFold, comforter] }

    // MARK: Snap to itemize

    func testLabelsBecomeTheShopsOwnLines() {
        let found = GarmentMatcher.suggestions(
            labels: [("suit", 0.8), ("jeans", 0.5), ("gown", 0.4)], menu: menu)
        XCTAssertEqual(found, [suit, pants, dress])
    }

    func testUnsureLabelsAreIgnored() {
        XCTAssertTrue(GarmentMatcher.suggestions(labels: [("suit", 0.1)], menu: menu).isEmpty)
    }

    func testClothesWithNoNameableGarmentPointAtLaundry() {
        XCTAssertEqual(GarmentMatcher.suggestions(labels: [("clothing", 0.9)], menu: menu), [washFold])
    }

    func testALabelTheShopDoesNotSellIsDropped() {
        XCTAssertTrue(GarmentMatcher.suggestions(labels: [("necktie", 0.9)], menu: menu).isEmpty)
    }

    // MARK: Care labels

    func testCareLabels() {
        XCTAssertEqual(CareAdvice.read(["100% WOOL", "DRY CLEAN ONLY"]), .dryClean)
        XCTAssertEqual(CareAdvice.read(["MACHINE WASH COLD", "TUMBLE DRY LOW"]), .washable)
        XCTAssertEqual(CareAdvice.read(["Machine wash cold", "DO NOT DRY CLEAN"]), .washable)
        XCTAssertEqual(CareAdvice.read(["Do not wash", "Dry clean"]), .dryClean)
        XCTAssertEqual(CareAdvice.read(["LIMPIAR EN SECO"]), .dryClean)
        XCTAssertEqual(CareAdvice.read(["MADE IN ITALY"]), .unknown)
        XCTAssertEqual(CareAdvice.read([]), .unknown)
    }

    /// Live Text on a real rendered label, end to end through Vision.
    func testVisionReadsACareLabelOffAnImage() async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 300)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
            ("DRY CLEAN ONLY" as NSString).draw(
                at: CGPoint(x: 60, y: 110),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.black]
            )
        }
        let lines = await OnDeviceVision.readText(image)
        XCTAssertEqual(CareAdvice.read(lines), .dryClean, "Vision read: \(lines)")
    }

    // MARK: Shop tickets

    private let fulton = Cleaner(
        id: UUID(), name: "Fulton Cleaners", phone: "+17185550142",
        line1: "909 Fulton St", city: "Brooklyn", state: "NY",
        turnaroundHours: 48, lat: nil, lng: nil
    )
    private let bedford = Cleaner(
        id: UUID(), name: "Bedford Laundromat", phone: "+17185550199",
        line1: nil, city: "Brooklyn", state: "NY",
        turnaroundHours: 24, lat: nil, lng: nil
    )

    func testATicketGivesItsNumberAndShop() {
        let lines = ["FULTON CLEANERS", "909 Fulton St Brooklyn", "(718) 555-0142",
                     "Ticket # 4471", "10/07/26", "Total $12.50"]
        let reading = TicketReader.read(lines, shops: [bedford, fulton])
        XCTAssertEqual(reading.number, "4471")
        XCTAssertEqual(reading.shopId, fulton.id)
    }

    func testAnUnlabelledNumberIsFoundButPhonesDatesAndPricesAreNot() {
        let lines = ["(718) 555-0199", "10/07/2026", "$18.00", "58213"]
        XCTAssertEqual(TicketReader.number(in: lines), "58213")
        XCTAssertEqual(TicketReader.shop(in: lines, shops: [fulton, bedford])?.id, bedford.id)
    }

    // MARK: Book in plain English

    func testCountsAndGarments() {
        let parsed = OrderTextParser.parse("2 suits and a coat, plus 3 dress shirts", menu: menu)
        XCTAssertEqual(parsed.quantities[suit.id], 2)
        XCTAssertEqual(parsed.quantities[coat.id], 1)
        XCTAssertEqual(parsed.quantities[shirt.id], 3)
        XCTAssertEqual(parsed.service, .dryClean)
    }

    func testPoundsGoToTheWeighedLine() {
        let parsed = OrderTextParser.parse("about 15 lbs of laundry", menu: menu)
        XCTAssertEqual(parsed.quantities[washFold.id], 15)
        XCTAssertEqual(parsed.service, .washFold)
    }

    func testLaundryWithNoWeightOpensAtTheFloor() {
        let parsed = OrderTextParser.parse("just my laundry", menu: menu)
        XCTAssertEqual(parsed.quantities[washFold.id], 10)
    }

    func testThingsTheShopDoesNotSellAreReported() {
        let parsed = OrderTextParser.parse("2 shirts and 4 socks", menu: menu)
        XCTAssertEqual(parsed.quantities[shirt.id], 2)
        XCTAssertEqual(parsed.unmatched, ["socks"])
    }

    func testANamedTimeBecomesThePickup() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 18))!
        let when = OrderTextParser.pickupDate(in: "pick up tomorrow at 9am", now: now)
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9))!
        XCTAssertEqual(when, expected)
        XCTAssertNil(OrderTextParser.pickupDate(in: "yesterday at 9am", now: now), "past times are ignored")
    }

    // MARK: Your usual

    private func order(_ status: OrderStatus, daysAgo: Double, shop: Cleaner, items: [(String, Int)]) -> Order {
        let when = Date().addingTimeInterval(-daysAgo * 86400)
        return Order(
            id: UUID(), shortCode: "CR", status: status, serviceTier: "round_trip",
            estimateSubtotalCents: 0, subtotalCents: nil, totalCents: nil,
            deliveryFeeCents: 2995, serviceFeeCents: 0,
            pickupWindowStart: when, pickupWindowEnd: when,
            returnWindowStart: nil, returnWindowEnd: nil, estimatedReadyAt: nil, readyAt: nil,
            customerNotes: nil, cleanerNotes: nil, customerItemCount: nil, cleanerItemCount: nil,
            createdAt: when, cleaner: shop,
            address: Address(id: UUID(), label: "Home", line1: "251 Dekalb Ave", line2: nil,
                             city: "Brooklyn", state: "NY", postalCode: "11205",
                             accessNotes: "Buzz 4B", lat: 40.6896, lng: -73.9692),
            orderItems: items.map { OrderItem(id: UUID(), label: $0.0, quantity: $0.1, unitPriceCents: 0) },
            deliveryLegs: nil
        )
    }

    func testTheUsualIsTheLatestOrderAtTheMostUsedShop() {
        let orders = [
            order(.delivered, daysAgo: 14, shop: fulton, items: [("Laundered shirt", 5)]),
            order(.delivered, daysAgo: 7, shop: fulton, items: [("Laundered shirt", 4), ("Two-piece suit", 1)]),
            order(.delivered, daysAgo: 3, shop: bedford, items: [("Wash & fold", 12)]),
            order(.cancelled, daysAgo: 1, shop: bedford, items: [("Wash & fold", 20)]),
        ]
        let usual = UsualOrder.from(orders)
        XCTAssertEqual(usual?.cleanerId, fulton.id)
        XCTAssertEqual(usual?.lines, ["Laundered shirt": 4, "Two-piece suit": 1])
        XCTAssertEqual(usual?.address.accessNotes, "Buzz 4B")
        XCTAssertEqual(usual?.quantities(on: menu), [shirt.id: 4, suit.id: 1])
    }

    func testOneOrderOrUnpaidDraftsAreNotAUsual() {
        XCTAssertNil(UsualOrder.from([order(.delivered, daysAgo: 2, shop: fulton, items: [("Dress", 1)])]))
        XCTAssertNil(UsualOrder.from([
            order(.draft, daysAgo: 2, shop: fulton, items: [("Dress", 1)]),
            order(.draft, daysAgo: 1, shop: fulton, items: [("Dress", 1)]),
        ]))
    }

    // MARK: The shop's note

    func testTheShopNoteCarriesTicketStainsCareAndPhotos() {
        let at = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!
        let note = ShopNote.compose(
            stainNotes: ["red wine, left cuff", " "],
            careNotes: ["Care label: dry clean"],
            ticket: "4471",
            handoffPhotoCount: 2,
            handoffAt: at
        )
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.hasPrefix("Ticket #4471\nStain: red wine, left cuff\nCare label: dry clean\n2 handoff photos taken at"))
        XCTAssertNil(ShopNote.compose(stainNotes: []))
    }

    func testATranslationKeepsTheOriginal() {
        let both = ShopNote.withTranslation("Stain: red wine", translated: "얼룩: 레드 와인")
        XCTAssertTrue(both.hasPrefix("얼룩: 레드 와인"))
        XCTAssertTrue(both.hasSuffix("Stain: red wine"))
        XCTAssertEqual(ShopNote.withTranslation("Same", translated: nil), "Same")
    }

    func testTranslationOnlyWhenTheShopReadsAnotherLanguage() {
        let english = Locale(identifier: "en_US")
        XCTAssertNil(NoteTranslator.targetLanguage(shop: "en", phone: english))
        XCTAssertNil(NoteTranslator.targetLanguage(shop: nil, phone: english))
        XCTAssertEqual(NoteTranslator.targetLanguage(shop: "ko", phone: english), "ko")
    }

    // MARK: Weight from a photo

    func testAContainerAndFullnessGiveARoughWeight() {
        let half = WeightEstimate.from(container: .basket, fullness: 0.5, heavy: false)
        XCTAssertEqual(half.pounds, 6)
        XCTAssertEqual(WeightEstimate.from(container: .basket, fullness: 1, heavy: false).pounds, 12)
        XCTAssertEqual(WeightEstimate.from(container: .basket, fullness: 1, heavy: true).pounds, 16,
                       "towels and bedding weigh about a third more")
        let full = WeightEstimate.from(container: .hamper, fullness: 1, heavy: false)
        XCTAssertLessThan(full.low, full.pounds)
        XCTAssertGreaterThan(full.high, full.pounds)
    }

    func testTheEstimateNeverLeavesTheSteppersRange() {
        XCTAssertGreaterThanOrEqual(WeightEstimate.from(cubicFeet: 0, heavy: false).pounds, 1)
        XCTAssertLessThanOrEqual(WeightEstimate.from(cubicFeet: 500, heavy: true).pounds, 200)
    }

    func testTheContainerIsReadFromVisionsLabels() {
        XCTAssertEqual(LaundryContainer.from(labels: [("basket_container", 0.6), ("clothing", 0.9)]), .basket)
        XCTAssertEqual(LaundryContainer.from(labels: [("sack", 0.4)]), .laundryBag)
        XCTAssertNil(LaundryContainer.from(labels: [("clothing", 0.9)]))
    }

    /// A 40 x 40 cm pile, 30 cm tall, sampled every 2 cm on top, over a floor
    /// at y = -1.2 m: 0.048 m³ = 1.70 ft³. Points on the floor itself and a
    /// stray ceiling reading must not count.
    func testThePileVolumeIsTheHeightFieldAboveTheFloor() {
        let floor: Float = -1.2
        var points: [SIMD3<Float>] = []
        // Sampled inside cells (0.01, 0.03, ...): points exactly on a 4 cm
        // border fall either side through float rounding and add a ring.
        for x in stride(from: Float(0.01), to: 0.4, by: 0.02) {
            for z in stride(from: Float(0.01), to: 0.4, by: 0.02) {
                points.append(SIMD3(x, floor + 0.3, z))
                points.append(SIMD3(x + 0.6, floor, z))
            }
        }
        points.append(SIMD3(0.1, floor + 2.5, 0.1))
        let cubicFeet = PileVolume.cubicFeet(points: points, floorY: floor)
        XCTAssertEqual(cubicFeet, 1.70, accuracy: 0.05)
        XCTAssertEqual(WeightEstimate.from(cubicFeet: cubicFeet, heavy: false).pounds, 11)
    }
}
