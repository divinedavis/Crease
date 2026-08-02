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
        case .failed: "Something went wrong — we're on it."
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

    var isActive: Bool {
        self != .delivered && self != .cancelled && self != .failed
    }

    /// Whether the customer can still call it off.
    ///
    /// The line is physical custody, not convenience: once a courier has the
    /// bag, cancelling would strand someone else's clothes in a stranger's
    /// car, and once the shop has started cleaning there is work to pay for.
    /// Before a courier is holding anything, cancelling is free and should be
    /// one tap.
    var isCancellable: Bool {
        [.draft, .scheduled, .pickupDispatched].contains(self)
    }

    /// A courier may already be on their way, so the carrier can bill us for
    /// the trip even though nothing was collected. Say so before charging it.
    var cancellationMayCost: Bool { self == .pickupDispatched }

    /// True while a courier is physically holding the order.
    var hasCourierEnRoute: Bool {
        [.pickupDispatched, .inTransitToCleaner, .returnDispatched, .inTransitToCustomer].contains(self)
    }
}

struct Cleaner: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
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
        case id, name, line1, city, state, lat, lng
        case turnaroundHours = "turnaround_hours"
    }

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

struct ServiceItem: Codable, Identifiable, Hashable {
    let id: UUID
    let code: String
    let label: String
    let unitPriceCents: Int

    enum CodingKeys: String, CodingKey {
        case id, code, label
        case unitPriceCents = "unit_price_cents"
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
    let courierName: String?
    let courierVehicle: String?
    let trackingUrl: String?
    let dropoffPincode: String?

    enum CodingKeys: String, CodingKey {
        case id, leg, status
        case courierName = "courier_name"
        case courierVehicle = "courier_vehicle"
        case trackingUrl = "tracking_url"
        case dropoffPincode = "dropoff_pincode"
    }

    var isLive: Bool {
        !["delivered", "returned", "cancelled", "failed"].contains(status)
    }
}

struct Order: Codable, Identifiable, Hashable {
    let id: UUID
    let shortCode: String
    let status: OrderStatus
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
    let createdAt: Date
    let cleaner: Cleaner?
    let address: Address?
    let orderItems: [OrderItem]?
    let deliveryLegs: [DeliveryLeg]?

    enum CodingKeys: String, CodingKey {
        case id, status, cleaner, address
        case shortCode = "short_code"
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
        case createdAt = "created_at"
        case orderItems = "order_items"
        case deliveryLegs = "delivery_legs"
    }

    /// What the customer owes right now: the counted total once it exists,
    /// the estimate before that. Never show a counted price as an estimate or
    /// the reverse — that is the difference between a quote and a bill.
    var displayCents: Int { totalCents ?? subtotalCents ?? estimateSubtotalCents }
    var isEstimate: Bool { subtotalCents == nil }

    var liveLeg: DeliveryLeg? { deliveryLegs?.first(where: \.isLive) }

    var itemCount: Int { orderItems?.reduce(0) { $0 + $1.quantity } ?? 0 }

    /// The clothes are done and no delivery has been booked, so the customer
    /// owes us a choice. This is the one moment the app should be asking for
    /// something rather than reporting.
    var needsReturnScheduling: Bool {
        readyAt != nil && returnWindowStart == nil && status == .ready
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
