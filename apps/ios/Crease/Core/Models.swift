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
        case .ready: "Ready — coming back soon"
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
        case .cleaning: "Usually ready within 48 hours."
        case .ready: "We'll bring it back in your delivery window."
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

    /// True while a courier is physically holding the order.
    var hasCourierEnRoute: Bool {
        [.pickupDispatched, .inTransitToCleaner, .returnDispatched, .inTransitToCustomer].contains(self)
    }
}

struct Cleaner: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let city: String
    let state: String
    let turnaroundHours: Int

    enum CodingKeys: String, CodingKey {
        case id, name, city, state
        case turnaroundHours = "turnaround_hours"
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

    enum CodingKeys: String, CodingKey {
        case id, label, line1, line2, city, state
        case postalCode = "postal_code"
        case accessNotes = "access_notes"
    }

    var oneLine: String {
        [line1, line2, city, "\(state) \(postalCode)"]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
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
