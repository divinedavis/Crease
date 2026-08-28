import CoreLocation
import Foundation

/// Mirrors the `order_status` enum in the database.
///
/// The customer-facing wording deliberately differs from the raw value: nobody
/// waiting on their shirts thinks in terms of `in_transit_to_cleaner`. The
/// copy answers the only question they actually have, which is "where are my
/// clothes and when do I get them back".
enum OrderStatus: String, Codable, CaseIterable {
    case draft, scheduled
    case pickupDispatched = "pickup_dispatched"
    case inTransitToCleaner = "in_transit_to_cleaner"
    case atCleaner = "at_cleaner"
    case awaitingApproval = "awaiting_approval"
    case cleaning, ready
    case returnDispatched = "return_dispatched"
    case inTransitToCustomer = "in_transit_to_customer"
    case delivered, cancelled, failed

    var title: String {
        switch self {
        case .draft: "Draft"
        case .scheduled: "Pickup scheduled"
        case .pickupDispatched: "Driver on the way"
        case .inTransitToCleaner: "Heading to the cleaner"
        case .atCleaner: "At the cleaner"
        case .awaitingApproval: "Needs your approval"
        case .cleaning: "Being cleaned"
        case .ready: "Ready for delivery"
        case .returnDispatched: "Driver collecting your order"
        case .inTransitToCustomer: "Out for delivery"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        case .failed: "Needs attention"
        }
    }

    var detail: String {
        switch self {
        // A draft is a booking whose card never went through. Left blank it
        // rendered as a card saying "Draft" and nothing else, which explains
        // neither why it is stuck nor that the customer can still finish it.
        case .draft: "Payment wasn't completed, so no driver has been booked. Tap to pay or cancel."
        case .scheduled: "We'll send a driver in your pickup window."
        case .pickupDispatched: "They'll text when they're outside."
        case .inTransitToCleaner: "Your bag is on its way to the shop."
        case .atCleaner: "They're counting your items now."
        case .awaitingApproval: "The final count came in above your estimate."
        case .cleaning: "The shop will tell you when it's done."
        case .ready: "Pick a time and we'll bring it back."
        case .returnDispatched: "A driver is picking it up from the shop."
        case .inTransitToCustomer: "Almost there."
        case .delivered: "Thanks for using Crease."
        // Almost always a paid order no courier accepted. "We're on it" told
        // someone whose money had already moved that there was nothing to do,
        // when the one thing they can do — get it back — is on this screen.
        case .failed: "We couldn't book a driver for this order. You can cancel it for a refund."
        default: ""
        }
    }

    /// Drives the progress indicator. Cancelled/failed sit outside the track.
    ///
    /// Indexes into ["Pickup", "At cleaner", "Cleaning", "Return"], and the
    /// mapping has to be exact: lighting "Cleaning" the moment a bag is
    /// dropped off tells the customer work has started when the shop has not
    /// even counted it yet, which is the difference between a status and a
    /// small lie. Pickup stays lit for the whole first leg — the bag is still
    /// in a car, not at the shop.
    var stepIndex: Int? {
        switch self {
        case .draft, .scheduled, .pickupDispatched, .inTransitToCleaner: 0
        case .atCleaner, .awaitingApproval: 1
        case .cleaning: 2
        case .ready, .returnDispatched, .inTransitToCustomer: 3
        case .delivered: 4
        case .cancelled, .failed: nil
        }
    }

    /// Whether the order still belongs at the top of the list.
    ///
    /// `failed` counts. It is not a finished order — it is a paid one with no
    /// courier — and filing it under Past orders is how a customer is charged
    /// for a pickup that never happened and never finds out.
    var isActive: Bool {
        self != .delivered && self != .cancelled
    }

    /// Whether the customer can still call it off.
    ///
    /// The line is physical custody, not convenience: once a courier has the
    /// bag, cancelling would strand someone else's clothes in a stranger's
    /// car, and once the shop has started cleaning there is work to pay for.
    /// Before a courier is holding anything, cancelling is free and should be
    /// one tap. `failed` is the extreme case of that — nobody ever collected
    /// anything, and cancelling is the only way the fee comes back.
    var isCancellable: Bool {
        [.draft, .scheduled, .pickupDispatched, .failed].contains(self)
    }

    /// A courier may already be on their way, so the carrier can bill us for
    /// the trip even though nothing was collected. Say so before charging it.
    var cancellationMayCost: Bool { self == .pickupDispatched }

    /// True while a courier is physically holding the order.
    var hasCourierEnRoute: Bool {
        [.pickupDispatched, .inTransitToCleaner, .returnDispatched, .inTransitToCustomer].contains(self)
    }
}

/// Turning whatever a phone number arrives as into something a person can read
/// and a phone can dial.
///
/// Lived on `Cleaner` until the customer needed to call their driver too.
/// Copying the two functions would have been the smaller diff and the worse
/// one: they encode a judgement about what counts as dialable, and two copies
/// of a judgement drift.
enum PhoneNumber {
    /// Shops give us whatever shape they use — `+15555550201`, `555-555-0201`
    /// — and carriers hand back an E.164 proxy line. A bare E.164 string in the
    /// middle of a sentence is something people read twice to be sure of.
    static func formatted(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        let local = digits.count == 11 && digits.hasPrefix("1") ? String(digits.dropFirst()) : digits
        guard local.count == 10 else { return raw }
        return "(\(local.prefix(3))) \(local.dropFirst(3).prefix(3))-\(local.suffix(4))"
    }

    /// Only when there is something real to dial. A `tel:` built from a blank
    /// or truncated number opens an empty dialer, which reads as the tap having
    /// failed rather than as nobody having given us a number.
    static func callURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 10 else { return nil }
        return URL(string: "tel:\(raw.hasPrefix("+") ? "+" : "")\(digits)")
    }
}

struct Cleaner: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    // Three cards tell the customer to call the shop. Without this they name
    // it and stop there, which is an instruction with nowhere to go.
    let phone: String?
    let line1: String?
    let city: String
    let state: String
    let turnaroundHours: Int
    // Needed to draw the route and to rank shops by distance. Previously the
    // map hardcoded one shop's coordinates, so every order looked like it was
    // going to the same place regardless of which shop it was going to.
    let lat: Double?
    let lng: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, phone, line1, city, state, lat, lng
        case turnaroundHours = "turnaround_hours"
    }

    /// The number as a person reads it.
    var formattedPhone: String? { PhoneNumber.formatted(phone) }

    var callURL: URL? { PhoneNumber.callURL(phone) }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Straight-line miles from a pickup point. Good enough to rank a handful
    /// of shops; the courier fee comes from the carrier, not from this.
    func milesFrom(_ point: CLLocationCoordinate2D) -> Double? {
        guard let coordinate else { return nil }
        let a = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let b = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return a.distance(from: b) / 1609.34
    }
}

struct Address: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String?
    var line1: String
    var line2: String?
    var city: String
    var state: String
    var postalCode: String
    var accessNotes: String?
    // Carried through deliberately. Dropping these meant a saved address had
    // to be re-geocoded from its text every time, which is both slower and
    // less accurate than the point the customer already confirmed on a map.
    var lat: Double?
    var lng: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, line1, line2, city, state, lat, lng
        case postalCode = "postal_code"
        case accessNotes = "access_notes"
    }

    var oneLine: String {
        [line1, line2, city, "\(state) \(postalCode)"]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
    }

    /// Home and Work get their own glyphs; anything else is a generic pin.
    var symbol: String {
        switch (label ?? "").lowercased() {
        case "home": "house.fill"
        case "work", "office": "briefcase.fill"
        default: "mappin.circle.fill"
        }
    }

    /// True when two addresses are the same place, so a repeat booking reuses
    /// the saved row instead of adding a near-duplicate every time.
    func isSamePlace(as other: ResolvedAddress) -> Bool {
        line1.caseInsensitiveCompare(other.line1) == .orderedSame
            && postalCode == other.postalCode
    }
}

/// A line on a shop's own price list.
///
/// Each shop sets its own, which is the whole shape of the marketplace: the
/// app quotes the prices of the shop the customer picked, never an average and
/// never a Crease price list. Two shops two blocks apart can charge different
/// numbers for a shirt and the booking screen has to say so.
struct ServiceItem: Codable, Identifiable, Hashable {
    let id: UUID
    let code: String
    let label: String
    let unitPriceCents: Int
    /// 'dry_clean' | 'wash_fold' | 'press'. An order is one of these, and the
    /// database refuses a line that is not the order's own.
    let serviceType: String
    /// 'piece' or 'pound'. Without it "3" is ambiguous between three shirts
    /// and three pounds, and a per-pound price rendered per item is off by 10x.
    let unit: String
    /// The weight floor a laundry order is billed at however light the bag is.
    /// Zero for everything sold by the piece.
    let minimumUnits: Double

    enum CodingKeys: String, CodingKey {
        case id, code, label, unit
        case unitPriceCents = "unit_price_cents"
        case serviceType = "service_type"
        case minimumUnits = "minimum_units"
    }

    var isByWeight: Bool { unit == "pound" }
}

/// The services a customer chooses between, in the order they are offered.
///
/// Derived from what the chosen shop actually sells rather than hardcoded: a
/// dry cleaner with no laundry service must not be shown a laundry tab that
/// prices nothing.
enum ServiceKind: String, CaseIterable, Identifiable {
    case dryClean = "dry_clean"
    case washFold = "wash_fold"
    case press

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dryClean: return "Dry cleaning"
        case .washFold: return "Wash & fold"
        case .press: return "Press only"
        }
    }

    /// What the customer is being asked to count.
    var prompt: String {
        switch self {
        case .dryClean: return "What are you sending?"
        case .washFold: return "About how much laundry?"
        case .press: return "What needs pressing?"
        }
    }

    var symbol: String {
        switch self {
        case .dryClean: return "tshirt"
        case .washFold: return "washer"
        case .press: return "wand.and.sparkles"
        }
    }
}

struct OrderItem: Codable, Identifiable, Hashable {
    let id: UUID
    let label: String
    let quantity: Int
    let unitPriceCents: Int

    enum CodingKeys: String, CodingKey {
        case id, label, quantity
        case unitPriceCents = "unit_price_cents"
    }

    var totalCents: Int { quantity * unitPriceCents }
}

struct DeliveryLeg: Codable, Identifiable, Hashable {
    let id: UUID
    let leg: String
    let status: String
    let provider: String
    let courierName: String?
    /// The carrier's masked line to the driver, live only while the leg is.
    /// Uber Direct proxies it and stops routing once the delivery closes, and
    /// scrub_finished_leg_pii nulls it a few days later, so this is never a
    /// courier's own number and never outlives the job.
    let courierPhone: String?
    let courierVehicle: String?
    let trackingUrl: String?
    let dropoffPincode: String?
    /// When the courier took custody, and when they gave it up. The two facts
    /// the customer wants back from a leg that has already finished.
    let pickedUpAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, leg, status, provider
        case courierName = "courier_name"
        case courierPhone = "courier_phone"
        case courierVehicle = "courier_vehicle"
        case trackingUrl = "tracking_url"
        case dropoffPincode = "dropoff_pincode"
        case pickedUpAt = "picked_up_at"
        case completedAt = "completed_at"
    }

    var isLive: Bool {
        !["delivered", "returned", "cancelled", "failed"].contains(status)
    }

    var isPickup: Bool { leg == "pickup" }

    /// It ended the way it was meant to. Distinguished from merely finished:
    /// `returned` is also over, and it means the goods came back.
    var didDeliver: Bool { status == "delivered" }

    /// Where to watch the driver, when there is somewhere real to watch them.
    ///
    /// The mock courier hands back https://track.crease.local/<id>, a host that
    /// does not resolve — offering it is a browser error page dressed up as
    /// tracking, and it looks like the feature is broken rather than absent.
    var trackingURL: URL? {
        // Only surface a real https tracking link. The value comes from the
        // courier-provider integration (external data); anything non-https is
        // dropped so a bad row can't render a phishing or non-web link.
        guard provider != "mock", let trackingUrl,
              let url = URL(string: trackingUrl),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
}

struct Order: Codable, Identifiable, Hashable {
    let id: UUID
    let shortCode: String
    let status: OrderStatus
    /// Which courier legs were bought: `round_trip`, `pickup_only` or
    /// `return_only`. Written at booking and, until now, never read back — so
    /// a pickup-only order still asked for a delivery time and would have sent
    /// a second courier the one-leg price never covered.
    let serviceTier: String
    let estimateSubtotalCents: Int
    let subtotalCents: Int?
    let totalCents: Int?
    let deliveryFeeCents: Int
    let serviceFeeCents: Int
    let pickupWindowStart: Date?
    let pickupWindowEnd: Date?
    let returnWindowStart: Date?
    let returnWindowEnd: Date?
    /// The shop's estimate, set at intake. A promise.
    let estimatedReadyAt: Date?
    /// When the shop actually finished. A fact — and what lets the customer
    /// schedule a return.
    let readyAt: Date?
    let customerNotes: String?
    let cleanerNotes: String?
    /// How many pieces the customer said they sent at booking. Optional — a
    /// claim, not a count, but it is the number the shop checks the bag
    /// against.
    let customerItemCount: Int?
    /// How many pieces the shop saw at the counter. Optional — the check.
    let cleanerItemCount: Int?
    let createdAt: Date
    let cleaner: Cleaner?
    let address: Address?
    let orderItems: [OrderItem]?
    let deliveryLegs: [DeliveryLeg]?

    enum CodingKeys: String, CodingKey {
        case id, status, cleaner, address
        case shortCode = "short_code"
        case serviceTier = "service_tier"
        case estimateSubtotalCents = "estimate_subtotal_cents"
        case subtotalCents = "subtotal_cents"
        case totalCents = "total_cents"
        case deliveryFeeCents = "delivery_fee_cents"
        case serviceFeeCents = "service_fee_cents"
        case pickupWindowStart = "pickup_window_start"
        case pickupWindowEnd = "pickup_window_end"
        case returnWindowStart = "return_window_start"
        case returnWindowEnd = "return_window_end"
        case estimatedReadyAt = "estimated_ready_at"
        case readyAt = "ready_at"
        case customerNotes = "customer_notes"
        case cleanerNotes = "cleaner_notes"
        case customerItemCount = "customer_item_count"
        case cleanerItemCount = "cleaner_item_count"
        case createdAt = "created_at"
        case orderItems = "order_items"
        case deliveryLegs = "delivery_legs"
    }

    /// The bag-check in one line: who counted what. Nil while nobody has.
    ///
    /// The two numbers are shown together because the difference is the whole
    /// point — agreement is reassurance, disagreement is a conversation to
    /// have while the clothes are still findable.
    var bagCheckText: String? {
        switch (customerItemCount, cleanerItemCount) {
        case (nil, nil): return nil
        case let (mine?, nil): return "\(mine) — your count"
        case let (nil, theirs?): return "\(theirs) — counted by the cleaner"
        case let (mine?, theirs?):
            return mine == theirs
                ? "\(theirs) — confirmed by the cleaner"
                : "You counted \(mine), the cleaner counted \(theirs)"
        }
    }

    /// What the customer owes right now: the counted total once it exists,
    /// the estimate before that. Never show a counted price as an estimate or
    /// the reverse — that is the difference between a quote and a bill.
    var displayCents: Int { totalCents ?? subtotalCents ?? estimateSubtotalCents }
    var isEstimate: Bool { subtotalCents == nil }

    /// Whether anyone has put a number on the cleaning yet.
    ///
    /// Nobody can price a bag before opening it, so booking writes
    /// `estimate_subtotal_cents = 0` and it stays zero until the shop counts.
    /// Rendered as money that zero read "$0.00 est." on every open order —
    /// a quote of free, on the one part of the bill Crease does not set.
    var hasPrice: Bool {
        totalCents != nil || subtotalCents != nil || estimateSubtotalCents > 0
    }

    /// The cleaning price, or nil while there genuinely isn't one.
    var priceText: String? { hasPrice ? displayCents.asMoney : nil }

    /// Why the approval screen exists, in the customer's terms.
    ///
    /// Without an estimate there is nothing to be "above" — the line the count
    /// crossed is the hold on the card, which is what the server actually
    /// compares against before it refuses to capture.
    var overageReason: String {
        estimateSubtotalCents > 0
            ? "above your \(estimateSubtotalCents.asMoney) estimate."
            : "above the amount held on your card."
    }

    var liveLeg: DeliveryLeg? { deliveryLegs?.first(where: \.isLive) }

    /// Legs that are over, oldest first.
    ///
    /// The courier card only ever describes the live leg, so the moment a
    /// driver finished, every trace of them left the screen — a bag could be
    /// collected, carried across Brooklyn and handed over, and the only
    /// evidence was one more lit segment on the track. Ordered by when they
    /// ended so a round trip reads top to bottom.
    var finishedLegs: [DeliveryLeg] {
        (deliveryLegs ?? [])
            .filter { !$0.isLive }
            .sorted { ($0.completedAt ?? .distantFuture) < ($1.completedAt ?? .distantFuture) }
    }

    var itemCount: Int { orderItems?.reduce(0) { $0 + $1.quantity } ?? 0 }

    /// Whether a courier has ever taken custody of this bag.
    ///
    /// This is the line the service refunds on, so the app has to draw it the
    /// same way or it promises money back that is not coming: a pickup leg
    /// that reached 'delivered' means the clothes are at the shop, and
    /// cancelling from there keeps the whole charge.
    var bagCollected: Bool {
        (deliveryLegs ?? []).contains { $0.isPickup && $0.didDeliver }
    }

    /// Whether a carrier has been put on the job and will bill for the abort.
    ///
    /// Mirrors the service's own list, terminal states included — that is the
    /// point of it. An order lands in 'failed' both when no courier could ever
    /// be booked, which refunds in full, and when the return leg ran out of
    /// attempts, by which point couriers have been paid and clothes cleaned.
    /// The status cannot tell those apart; the legs can.
    var courierEngaged: Bool {
        (deliveryLegs ?? []).contains {
            ["courier_assigned", "en_route_to_pickup", "at_pickup", "picked_up",
             "en_route_to_dropoff", "at_dropoff", "delivered", "returned"].contains($0.status)
        }
    }

    /// Pickup only: the courier fee bought one leg, to the shop. The clothes
    /// come home in the customer's hands.
    var isPickupOnly: Bool { serviceTier == "pickup_only" }

    /// Return only: the fee bought the leg home. Nobody is collecting — the
    /// bag gets to the shop because the customer carries it there.
    var isReturnOnly: Bool { serviceTier == "return_only" }

    /// The tier in the customer's own words — the same names the booking
    /// screen offered, read back from the one list that defines them so the
    /// two can never drift apart.
    var serviceTierName: String {
        ServiceOption.all.first { $0.id == serviceTier }?.name
            ?? serviceTier.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// What the address on the order is actually used for, which is not the
    /// same in all three tiers. Calling it "Pickup & delivery" on a one-leg
    /// order describes a service the customer did not buy: on pickup-only
    /// nobody is delivering to it, and on return-only nobody is collecting
    /// from it.
    var addressLabel: String {
        if isPickupOnly { return "Pickup address" }
        if isReturnOnly { return "Delivery address" }
        return "Pickup & delivery"
    }

    /// The journey track's labels, for the legs this order paid for.
    ///
    /// The last step is the one that differs: a round trip and a return-only
    /// order end with a driver at the door, a pickup-only order ends at the
    /// shop counter. The first differs too — return-only starts with the
    /// customer carrying the bag in, not a courier arriving.
    var journeySteps: [String] {
        let first = isReturnOnly ? "Drop off" : "Pickup"
        let last = isPickupOnly ? "Collect" : "Return"
        return [first, "At cleaner", "Cleaning", last]
    }

    /// Paid, and waiting on the customer to walk the bag in.
    ///
    /// Return-only used to be jumped straight to 'at_cleaner' when the payment
    /// cleared, which claimed the shop was counting items still sitting in the
    /// customer's hallway. It sits at 'scheduled' now, which is true and needs
    /// saying, because 'scheduled' otherwise means a driver is coming.
    var awaitsCustomerDropOff: Bool {
        status == .scheduled && isReturnOnly
    }

    /// The clothes are done and no delivery has been booked, so the customer
    /// owes us a choice. This is the one moment the app should be asking for
    /// something rather than reporting.
    var needsReturnScheduling: Bool {
        readyAt != nil && returnWindowStart == nil && status == .ready && !isPickupOnly
    }

    /// Same moment, other tier: done, but nobody is bringing it back. Asking
    /// for a delivery time here would be selling a leg that was never paid for.
    var awaitsCounterCollection: Bool {
        status == .ready && isPickupOnly
    }

    /// Whether the bag has stopped being a courier's problem.
    ///
    /// Read off the journey track rather than listed status by status, because
    /// it is the same line the track already draws: everything from the shop's
    /// counter onwards is past the pickup, and a pickup window shown past it
    /// is a time that has already been and gone.
    var hasReachedCleaner: Bool { (status.stepIndex ?? 0) >= 1 }

    /// Whether "Ready by" is worth a row.
    ///
    /// A null estimate shows nothing at all. The number the customer reads has
    /// to be the number the shop is working to, and one computed on the phone
    /// from a booking time would disagree with it the moment intake counts the
    /// bag and the turnaround changes — wash and fold is hours, dry cleaning
    /// is days, and the app cannot know which until the shop says.
    var showsReadyEstimate: Bool {
        hasReachedCleaner && status.isActive && readyAt == nil && estimatedReadyAt != nil
    }

    /// The estimate rendered as a window.
    ///
    /// To the minute it reads as a commitment the shop never made; ±30 minutes
    /// is the same number told honestly, and it is the shape people already
    /// expect from a delivery estimate.
    var readyWindowText: String? {
        guard let estimate = estimatedReadyAt else { return nil }
        let start = estimate.addingTimeInterval(-30 * 60)
        let end = estimate.addingTimeInterval(30 * 60)
        let calendar = Calendar.current
        let sameDay = calendar.isDate(start, inSameDayAs: end)
        // "5:50 PM – 6:50 PM" reads as two separate times when it is one
        // window. The shortcut only holds inside a single half of a single day
        // — across noon or midnight the shorter form reads backwards.
        let sameHalfOfDay = sameDay
            && (calendar.component(.hour, from: start) < 12)
                == (calendar.component(.hour, from: end) < 12)
        let from = sameHalfOfDay ? Self.timeWithoutDayPeriod(start) : Self.time(start)
        let to = sameDay
            ? Self.time(end)
            : "\(end.formatted(.dateTime.month(.abbreviated).day())), \(Self.time(end))"
        return "\(start.formatted(.dateTime.month(.abbreviated).day())), ~\(from) – \(to)"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The same time with the repeated AM/PM taken off.
    ///
    /// Trimmed from the formatted string rather than asked for as a format:
    /// the hour skeleton that omits the marker zero-pads the hour too, and
    /// "~05:50" reads like a clock readout rather than a time of day. A locale
    /// that has no marker, or puts it somewhere other than the end, is left
    /// exactly as it formatted itself.
    private static func timeWithoutDayPeriod(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let text = formatter.string(from: date)
        for marker in [formatter.amSymbol, formatter.pmSymbol].compactMap({ $0 })
        where !marker.isEmpty && text.hasSuffix(marker) {
            return String(text.dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// The status wording, corrected for what the customer actually bought.
    /// The raw status cannot know: `ready` means "pick a delivery time" on a
    /// round trip and "come and get it" on a pickup-only order, and telling
    /// the second customer their order is out for delivery is a lie the app
    /// would then have to be caught in. `scheduled` divides the same way —
    /// a driver is coming, unless the tier is the one where nobody is.
    var statusTitle: String {
        if awaitsCounterCollection { return "Ready to collect" }
        if awaitsCustomerDropOff { return "Drop your bag off" }
        return status.title
    }

    var statusDetail: String {
        if awaitsCounterCollection {
            return "Waiting for you at \(cleaner?.name ?? "the shop")."
        }
        if awaitsCustomerDropOff {
            return "Take your bag to \(cleaner?.name ?? "the shop"). They'll count it in, and we'll deliver it back once it's ready."
        }
        return status.detail
    }
}

extension Int {
    /// Cents to display currency. Money is integer cents everywhere; this is
    /// the only place it becomes a string.
    var asMoney: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f.string(from: NSNumber(value: Double(self) / 100)) ?? "$0.00"
    }
}

extension Address {
    /// A saved address already has everything the flow needs, so picking one
    /// skips both the search and the pin step entirely — the fast path for a
    /// returning customer, who is most of them.
    var asResolved: ResolvedAddress {
        ResolvedAddress(
            line1: line1,
            city: city,
            state: state,
            postalCode: postalCode,
            // The stored point, not a placeholder — this is what a courier is
            // actually sent to.
            coordinate: CLLocationCoordinate2D(
                latitude: lat ?? CLLocationCoordinate2D.brooklyn.latitude,
                longitude: lng ?? CLLocationCoordinate2D.brooklyn.longitude
            )
        )
    }
}

/// The signed-in customer's own row.
///
/// Only the fields a person edits about themselves are here. The two Stripe
/// references on the same table are deliberately absent: migration 0032 revoked
/// the client's write grant on them precisely so this app can never touch them,
/// and a struct that names them is a struct that will eventually try.
struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var fullName: String?
    /// The number a courier dials from the doorstep. Optional because it is
    /// asked for at checkout rather than at sign-up — the first booking is the
    /// first moment it means anything.
    var phone: String?

    enum CodingKeys: String, CodingKey {
        case id, phone
        case fullName = "full_name"
    }

    /// The number as a person reads it, so someone checking their own contact
    /// details recognises them at a glance.
    var formattedPhone: String? {
        guard let phone, !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        let local = digits.count == 11 && digits.hasPrefix("1") ? String(digits.dropFirst()) : digits
        guard local.count == 10 else { return phone }
        return "(\(local.prefix(3))) \(local.dropFirst(3).prefix(3))-\(local.suffix(4))"
    }
}
