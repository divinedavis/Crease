import Foundation
import Supabase
import SwiftUI

/// Reads and writes orders for the signed-in customer.
///
/// Every query here runs under the customer's own JWT, so RLS is what scopes
/// the results — the client never sees another customer's data even if a
/// filter is wrong. Writes that move money or dispatch a courier are not here
/// at all: those go through the dispatch service, which holds the only
/// credentials that can do them.
@MainActor
final class OrderStore: ObservableObject {
    @Published private(set) var orders: [Order] = []
    @Published private(set) var cleaners: [Cleaner] = []
    @Published private(set) var addresses: [Address] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    /// The one task listening to both tables, and the refetch it has queued.
    private var watcher: Task<Void, Never>?
    private var pendingReload: Task<Void, Never>?

    init(client: SupabaseClient) {
        self.client = client
    }

    /// The signed-in customer's access token, refreshed if needed.
    func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    private static let orderSelect = """
    id, short_code, status, service_tier, estimate_subtotal_cents, subtotal_cents, total_cents,
    delivery_fee_cents, service_fee_cents, pickup_window_start, pickup_window_end,
    return_window_start, return_window_end, estimated_ready_at, ready_at,
    customer_notes, cleaner_notes, customer_item_count, cleaner_item_count, created_at,
    cleaner:cleaners(id, name, phone, line1, city, state, turnaround_hours, lat, lng),
    address:addresses(id, label, line1, line2, city, state, postal_code, access_notes, lat, lng),
    order_items(id, label, quantity, unit_price_cents),
    delivery_legs(id, leg, status, provider, courier_name, courier_vehicle, tracking_url,
                  dropoff_pincode, picked_up_at, completed_at)
    """

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let o: () = loadOrders()
        async let c: () = loadCleaners()
        async let a: () = loadAddresses()
        _ = await (o, c, a)
    }

    /// The statuses that put an order in the past — the mirror of
    /// `OrderStatus.isActive`, which is what OrdersView splits the list on.
    private static let closedStatuses = OrderStatus.allCases
        .filter { !$0.isActive }
        .map(\.rawValue)

    /// How far back "Past orders" goes. A regular customer accumulates
    /// hundreds, every one of them dragging its cleaner, address, items and
    /// legs along, and the screen shows them as one-line rows nobody scrolls
    /// to the bottom of.
    private static let historyLimit = 25

    /// Two queries rather than one, because they want opposite things.
    ///
    /// Everything still in flight has to be here whatever its age — an order
    /// stuck at the shop for a month is the one the customer opens the app for,
    /// and a plain `.limit()` on a single query is exactly what would drop it.
    /// Finished orders are history, so they get a ceiling.
    func loadOrders() async {
        do {
            async let open: [Order] = client
                .from("orders")
                .select(Self.orderSelect)
                .notIn("status", values: Self.closedStatuses)
                .order("created_at", ascending: false)
                .execute()
                .value
            async let history: [Order] = client
                .from("orders")
                .select(Self.orderSelect)
                .in("status", values: Self.closedStatuses)
                .order("created_at", ascending: false)
                .limit(Self.historyLimit)
                .execute()
                .value
            let (active, past) = try await (open, history)
            orders = (active + past).sorted { $0.createdAt > $1.createdAt }
        } catch {
            errorMessage = "Couldn't load your orders."
        }
    }

    func loadCleaners() async {
        cleaners = (try? await client
            .from("cleaners")
            .select("id, name, phone, line1, city, state, turnaround_hours, lat, lng")
            .eq("active", value: true)
            .order("name")
            .execute()
            .value) ?? []
    }

    func loadAddresses() async {
        addresses = (try? await client
            .from("addresses")
            .select("id, label, line1, line2, city, state, postal_code, access_notes, lat, lng")
            .order("created_at")
            .execute()
            .value) ?? []
    }

    /// The chosen shop's own price list.
    ///
    /// Fetched per shop and never cached across shops: these are the prices the
    /// customer is about to be quoted, and showing one shop's shirt price under
    /// another shop's name is the one mistake a marketplace cannot make.
    func serviceMenu(for cleanerId: UUID) async -> [ServiceItem] {
        (try? await client
            .from("service_items")
            .select("id, code, label, unit_price_cents, service_type, unit, minimum_units")
            .eq("cleaner_id", value: cleanerId)
            .eq("active", value: true)
            .order("sort_order")
            .execute()
            .value) ?? []
    }

    /// Send the customer's own declaration of what is in the bag.
    ///
    /// Replaces rather than appends: a customer who backs out and re-picks must
    /// not have both attempts arrive at the counter. Writable only while the
    /// order is a draft — RLS and the validate trigger both say so, and the
    /// trigger also pins every price to the shop's published one, so nothing
    /// here is taken on trust.
    ///
    /// A failure is not fatal to the booking. The estimate is already on the
    /// order, the hold is sized from it, and the shop counts the bag anyway —
    /// losing the itemised list costs the counter a head start, not the order.
    @discardableResult
    func replaceDeclaredItems(orderId: UUID, lines: [(item: ServiceItem, entered: Double)]) async -> Bool {
        struct NewLine: Encodable {
            let order_id: UUID
            let service_item_id: UUID
            let label: String
            let quantity: Double
            let unit_price_cents: Int
        }

        do {
            try await client.from("order_items").delete().eq("order_id", value: orderId).execute()
            let rows = lines
                .filter { $0.entered > 0 }
                .map {
                    NewLine(
                        order_id: orderId,
                        service_item_id: $0.item.id,
                        label: $0.item.label,
                        // What they will be billed for, not what they typed: a
                        // bag under the shop's weight floor bills at the floor,
                        // and the estimate they just agreed to says so.
                        quantity: ServicePricing.billableUnits($0.item, entered: $0.entered),
                        unit_price_cents: $0.item.unitPriceCents
                    )
                }
            guard !rows.isEmpty else { return true }
            try await client.from("order_items").insert(rows).execute()
            return true
        } catch {
            return false
        }
    }

    struct NewAddress: Encodable {
        let user_id: UUID
        let label: String?
        let line1: String
        let city: String
        let state: String
        let postal_code: String
        let access_notes: String?
        // Stored so a saved address never has to be re-geocoded, and so the
        // point the customer confirmed on the map is the point a courier gets.
        var lat: Double? = nil
        var lng: Double? = nil
    }

    func addAddress(_ draft: NewAddress) async -> Address? {
        do {
            let saved: Address = try await client
                .from("addresses")
                .insert(draft)
                .select("id, label, line1, line2, city, state, postal_code, access_notes, lat, lng")
                .single()
                .execute()
                .value
            addresses.append(saved)
            return saved
        } catch {
            errorMessage = "Couldn't save that address."
            return nil
        }
    }

    struct NewOrder: Encodable {
        let customer_id: UUID
        let cleaner_id: UUID
        let address_id: UUID
        let status: String
        let estimate_subtotal_cents: Int
        /// What Crease charges. This is the whole price of an order — the
        /// cleaning is settled with the shop.
        var delivery_fee_cents: Int = 0
        var service_tier: String = "round_trip"
        /// Dry cleaning, laundry by the pound, or a press. Decides the shop's
        /// turnaround and which half of their price list the order is allowed
        /// to draw its lines from.
        var service_type: String = "dry_clean"
        let pickup_window_start: Date
        let pickup_window_end: Date
        let customer_notes: String?
        /// How many pieces they say are in the bag. Optional — nil is encoded
        /// as an absent key, so an uncounted bag stays null rather than zero.
        var customer_item_count: Int? = nil
    }

    /// The customer's own bag count, editable for as long as the row is still
    /// a draft. A retried payment reuses the draft row, and the number typed
    /// on this attempt should win over the one from the abandoned attempt —
    /// including clearing it, which is why nil is encoded as an explicit null.
    func setCustomerItemCount(orderId: UUID, count: Int?) async {
        struct Patch: Encodable {
            let customer_item_count: Int?
            enum CodingKeys: String, CodingKey { case customer_item_count }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(customer_item_count, forKey: .customer_item_count)
            }
        }
        _ = try? await client
            .from("orders")
            .update(Patch(customer_item_count: count))
            .eq("id", value: orderId)
            .execute()
    }

    func createOrder(_ draft: NewOrder) async -> Order? {
        do {
            let created: Order = try await client
                .from("orders")
                .insert(draft)
                .select(Self.orderSelect)
                .single()
                .execute()
                .value
            orders.insert(created, at: 0)
            return created
        } catch {
            errorMessage = "Couldn't schedule that pickup."
            return nil
        }
    }

    private struct ReturnWindow: Encodable {
        let start: Date
        let end: Date
    }

    /// Ask the dispatcher to book the return courier for the window the
    /// customer chose.
    ///
    /// The window used to be written straight to `orders` from here first.
    /// RLS lets a customer update their own order only at 'draft' or
    /// 'awaiting_approval', and this runs at 'ready' — so the write matched
    /// zero rows, reported no error, and the dispatch call that followed
    /// refused every time with "Choose a delivery time first." on a time that
    /// had been chosen. The service writes it now, with the one credential
    /// that is allowed to.
    func scheduleReturn(order: Order, start: Date, end: Date) async -> String? {
        do {
            _ = try await DispatchAPI(accessToken: try await accessToken()).post(
                "/v1/me/orders/\(order.id.uuidString.lowercased())/dispatch-return",
                body: ReturnWindow(start: start, end: end),
                as: DispatchAPI.Ack.self
            )
            await loadOrders()
            return nil
        } catch {
            await loadOrders()
            return "We couldn't schedule your delivery. Please try again."
        }
    }

    /// Call off an order.
    ///
    /// Routed through the dispatch service rather than written directly: the
    /// couriers have to be cancelled with the carrier and the payment released
    /// or refunded, and neither of those is something a phone should be
    /// trusted to do. Flipping the status column here would leave a courier
    /// still en route and the customer still charged.
    /// Returns nil only when the order was called off and the whole fee came
    /// back. Anything else is a sentence the customer has to read: a refund
    /// still being processed, or money the service has deliberately kept.
    func cancel(order: Order) async -> String? {
        do {
            let ack = try await DispatchAPI(accessToken: try await accessToken()).post(
                "/v1/me/orders/\(order.id.uuidString.lowercased())/cancel",
                as: DispatchAPI.Ack.self
            )
            await loadOrders()
            if ack.refundPending == true {
                return ack.message
                    ?? "Your pickup is cancelled, but the refund is still being processed."
            }
            // A cancellation that costs money answers 200 exactly like a free
            // one. The service keeps the whole charge once the bag has been
            // collected and keeps a cancellation fee once a courier has been
            // assigned, and it says so in `message` — dropping that because
            // `refundPending` was false is how someone finds out they were
            // charged from their bank statement instead of from us.
            if ack.refunded == false || (ack.retainedCents ?? 0) > 0 {
                return ack.message
                    ?? "Your order is cancelled, but the courier fee has not been refunded. Contact support and we'll sort it out."
            }
            return nil
        } catch let failure as DispatchAPI.Failure {
            // "This order can no longer be cancelled. Please call the shop." is
            // the answer, not a transport hiccup. Replacing it with generic
            // retry advice sends someone back at a route that will refuse them
            // the same way every time, and hides the one instruction that would
            // get their bag sorted out. Only the reason the service wrote for a
            // customer is shown; its status-code fallback is not one.
            return failure.serverReason
                ?? "We couldn't cancel your order. Please try again or contact support."
        } catch {
            return "We couldn't cancel your order. Please try again or contact support."
        }
    }

    /// Customer accepts an intake total above what was authorized.
    ///
    /// Only records the decision; capturing the hold and charging the
    /// difference happens server-side, because the client must never be the
    /// thing that decides how much someone is charged.
    func approve(order: Order) async -> Bool {
        do {
            // Through the dispatcher, not by writing the row. Stamping
            // `approved_at` looked like it recorded the decision and did not:
            // nothing on the server ever read that column, so the hold was
            // never captured and the difference never charged. It could not
            // even fail visibly — the update matches zero rows once the shop
            // has moved the order on, and PostgREST answers 204, so the app
            // reported success for an approval that did nothing at all.
            _ = try await DispatchAPI(accessToken: try await accessToken()).post(
                "/v1/me/orders/\(order.id.uuidString.lowercased())/approve",
                as: DispatchAPI.Ack.self
            )
            await loadOrders()
            return true
        } catch let failure as DispatchAPI.Failure {
            // The service says whether this is worth retrying — a decline rolls
            // the order back to awaiting_approval, so the customer can fix
            // their card and try the same button again.
            errorMessage = failure.serverReason ?? "We couldn't take that payment. Please try again."
            return false
        } catch {
            errorMessage = "We couldn't take that payment. Please try again."
            return false
        }
    }

    /// Abandon a draft the customer has replaced with a different choice.
    ///
    /// Routed through the same cancel call they could make by hand, because
    /// that is what releases the PaymentIntent the old draft already minted.
    /// Marking the row cancelled from here would leave a live intent on Stripe
    /// with nothing pointing at it. Failure is not worth a message: the draft
    /// stays visible and cancellable on the list, which is where they would go
    /// to deal with it anyway.
    func discardDraft(orderId: UUID) async {
        _ = try? await DispatchAPI(accessToken: try await accessToken()).post(
            "/v1/me/orders/\(orderId.uuidString.lowercased())/cancel",
            as: DispatchAPI.Ack.self
        )
    }

    /// Everything this account holds, as a JSON file the customer can keep.
    ///
    /// Read through their own session, so RLS is what decides what "their
    /// data" means and this cannot become a way to read anybody else's — the
    /// same rows the app already renders, without the shaping. `*` is
    /// deliberately not used on delivery_legs: that table also carries the
    /// courier's phone and live GPS, which the customer role is not granted,
    /// and asking for a column you cannot read fails the whole query.
    func exportAccountData() async throws -> URL {
        let profileRows = try await rawRows(client.from("profiles").select())
        let addressRows = try await rawRows(client.from("addresses").select().order("created_at"))
        let orderRows = try await rawRows(
            client.from("orders").select(Self.exportSelect).order("created_at", ascending: false)
        )

        let export: [String: Any] = [
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "source": "Crease for iOS",
            // One row, so hand it over as an object rather than a list of one.
            "profile": (profileRows as? [Any])?.first ?? NSNull(),
            "addresses": addressRows,
            "orders": orderRows,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: export, options: [.prettyPrinted, .sortedKeys]
        )
        // A named file, because the share sheet passes the filename on: what
        // lands in Files or in an email is "crease-data-2026-08-15.json"
        // rather than an untitled blob of text.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crease-data-\(Self.fileStamp.string(from: Date())).json")
        // completeFileProtection: this is the single most concentrated PII blob
        // the app produces (profile, home address with access notes, full order
        // and courier history), so it stays encrypted at rest and unreadable
        // while the device is locked. The caller deletes it once the share sheet
        // is done rather than leaving it for iOS to purge on its own schedule.
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private static let exportSelect = """
    *, order_items(*),
    cleaner:cleaners(id, name, phone, line1, city, state, postal_code),
    address:addresses(*),
    payments(id, kind, status, authorized_cents, captured_cents, refunded_cents, created_at),
    delivery_legs(id, leg, attempt, status, provider, tracking_url, fee_cents,
                  courier_name, courier_vehicle, dropoff_pincode,
                  dispatched_at, picked_up_at, completed_at, created_at)
    """

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        // Fixed locale: a filename is not a place for the reader's calendar.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The response body as parsed JSON, not as a model. An export should
    /// carry what the database holds, not the subset the screens decode.
    private func rawRows(_ builder: PostgrestBuilder) async throws -> Any {
        let data = try await builder.execute().data
        return (try? JSONSerialization.jsonObject(with: data)) ?? []
    }

    /// Push updates for this customer's orders.
    ///
    /// A tracking screen that only refreshes on pull is a tracking screen
    /// people refresh compulsively. RLS still filters what arrives.
    func startWatching() async {
        guard channel == nil else { return }
        let ch = client.realtimeV2.channel("customer-orders")
        let changes = ch.postgresChange(AnyAction.self, schema: "public", table: "orders")
        let legChanges = ch.postgresChange(AnyAction.self, schema: "public", table: "delivery_legs")
        await ch.subscribe()
        channel = ch

        // One task over both streams, so the pair can be cancelled together
        // and neither can outlive the channel it reads from.
        watcher = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in changes { await self?.reloadSoon() } }
                group.addTask { for await _ in legChanges { await self?.reloadSoon() } }
            }
        }
    }

    /// Collapse a burst of row changes into one refetch.
    ///
    /// A single pickup writes the order row and its leg over and over as the
    /// courier moves — a dozen events inside two seconds, each of which used
    /// to run the whole history query from its own task, racing itself for the
    /// list it assigns. The window is short enough that the screen still moves
    /// with the driver, and events arriving inside it are absorbed rather than
    /// queued: the reload that is already coming will see them.
    private func reloadSoon() {
        guard pendingReload == nil else { return }
        pendingReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            // Cleared first, so a change landing during the fetch schedules
            // the next one instead of being dropped.
            pendingReload = nil
            await loadOrders()
        }
    }

    func stopWatching() async {
        watcher?.cancel()
        watcher = nil
        pendingReload?.cancel()
        pendingReload = nil
        if let channel { await client.realtimeV2.removeChannel(channel) }
        channel = nil
    }
}
