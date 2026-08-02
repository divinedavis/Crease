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

    init(client: SupabaseClient) {
        self.client = client
    }

    private static let orderSelect = """
    id, short_code, status, estimate_subtotal_cents, subtotal_cents, total_cents,
    delivery_fee_cents, service_fee_cents, pickup_window_start, pickup_window_end,
    customer_notes, cleaner_notes, created_at,
    cleaner:cleaners(id, name, line1, city, state, turnaround_hours, lat, lng),
    address:addresses(id, label, line1, line2, city, state, postal_code, access_notes, lat, lng),
    order_items(id, label, quantity, unit_price_cents),
    delivery_legs(id, leg, status, courier_name, courier_vehicle, tracking_url, dropoff_pincode)
    """

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let o: () = loadOrders()
        async let c: () = loadCleaners()
        async let a: () = loadAddresses()
        _ = await (o, c, a)
    }

    func loadOrders() async {
        do {
            orders = try await client
                .from("orders")
                .select(Self.orderSelect)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = "Couldn't load your orders."
        }
    }

    func loadCleaners() async {
        cleaners = (try? await client
            .from("cleaners")
            .select("id, name, line1, city, state, turnaround_hours, lat, lng")
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

    func serviceMenu(for cleanerId: UUID) async -> [ServiceItem] {
        (try? await client
            .from("service_items")
            .select("id, code, label, unit_price_cents")
            .eq("cleaner_id", value: cleanerId)
            .eq("active", value: true)
            .order("sort_order")
            .execute()
            .value) ?? []
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
        let pickup_window_start: Date
        let pickup_window_end: Date
        let customer_notes: String?
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

    /// Customer accepts an intake total above what was authorized.
    ///
    /// Only records the decision; capturing the hold and charging the
    /// difference happens server-side, because the client must never be the
    /// thing that decides how much someone is charged.
    func approve(order: Order) async -> Bool {
        do {
            try await client
                .from("orders")
                .update(["approved_at": Date()])
                .eq("id", value: order.id)
                .execute()
            await loadOrders()
            return true
        } catch {
            errorMessage = "Couldn't record your approval."
            return false
        }
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

        Task { [weak self] in
            for await _ in changes {
                await self?.loadOrders()
            }
        }
        Task { [weak self] in
            for await _ in legChanges {
                await self?.loadOrders()
            }
        }
    }

    func stopWatching() async {
        if let channel { await client.realtimeV2.removeChannel(channel) }
        channel = nil
    }
}
