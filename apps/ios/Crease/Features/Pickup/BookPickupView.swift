import MapKit
import SwiftUI

/// The booking screen: route on a map, options in a sheet over it.
///
/// Modelled on the ride-hailing pattern people already know — see the map,
/// pick a tier, one confirm button that never moves. The important difference
/// is what the price means: this is the courier fee only. The cleaning bill is
/// settled with the shop, and the copy says so plainly rather than letting
/// someone discover it later.
struct BookPickupView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss

    let pickup: ResolvedAddress
    let accessNotes: String

    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: ServiceOption = .recommended
    @State private var cleaner: Cleaner?
    @State private var submitting = false
    @State private var error: String?
    @State private var pickupDay = Date()
    @State private var choosingCleaner = false
    @StateObject private var checkout = Checkout()
    @State private var draft: Draft?
    /// Whether this screen is still the one presented.
    ///
    /// The payment sheet goes up from whatever UIKit controller is topmost,
    /// which after a dismissal is the order list — so a booking that outlives
    /// its screen puts a sheet over Orders with nothing to explain it, and
    /// paying that sheet dispatches a courier for a booking the customer
    /// walked away from. Read from the environment rather than tracked with
    /// `onDisappear`: swapping the cover's item from the address step to this
    /// one delivers a disappear into the same slot after this view has already
    /// appeared, and a flag cleared by that event kills the live booking it
    /// was meant to protect.
    @Environment(\.isPresented) private var isPresented

    /// The order this screen already created, and the choice it was created
    /// for. Kept so a retry can pay for it instead of making another, and
    /// discarded as soon as the choice changes — the price and the shop are
    /// baked into the row at insert.
    private struct Draft {
        let id: UUID
        let tier: String
        let cleanerId: UUID
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
            header
        }
        .safeAreaInset(edge: .bottom) { optionsSheet }
        .sheet(isPresented: $choosingCleaner) {
            CleanerPickerView(
                cleaners: store.cleaners,
                pickup: pickup.coordinate,
                selected: cleaner
            ) { picked in
                withAnimation(.easeInOut(duration: 0.4)) { cleaner = picked }
                frameRoute()
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if store.cleaners.isEmpty { await store.loadCleaners() }
            // Nearest, not first alphabetically — but the customer can change
            // it, which is the point.
            cleaner = store.cleaners.min {
                ($0.milesFrom(pickup.coordinate) ?? .greatestFiniteMagnitude)
                    < ($1.milesFrom(pickup.coordinate) ?? .greatestFiniteMagnitude)
            }
            frameRoute()
        }
    }

    private var map: some View {
        Map(position: $camera) {
            Marker("Pickup", systemImage: "bag.fill", coordinate: pickup.coordinate)
                .tint(Theme.accent)
            if let c = cleanerCoordinate {
                Marker(cleaner?.name ?? "Cleaner", systemImage: "building.2.fill", coordinate: c)
                    .tint(.orange)
                MapPolyline(coordinates: [pickup.coordinate, c])
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 10]))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
    }

    private var cleanerCoordinate: CLLocationCoordinate2D? { cleaner?.coordinate }

    private func frameRoute() {
        guard let c = cleanerCoordinate else { return }
        let midLat = (pickup.coordinate.latitude + c.latitude) / 2
        let midLon = (pickup.coordinate.longitude + c.longitude) / 2
        let spanLat = abs(pickup.coordinate.latitude - c.latitude) * 2.6 + 0.008
        let spanLon = abs(pickup.coordinate.longitude - c.longitude) * 2.6 + 0.008
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            ))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Closed while a booking is in flight. The order row and the
            // payment intent are already being created by then, and leaving
            // this live means the customer can walk out mid-charge — there is
            // no cancel to offer them at that point, only a screen that has to
            // stay put until the sheet answers.
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .disabled(submitting)
            .accessibilityLabel("Back")

            HStack(spacing: 6) {
                Text(pickup.line1).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2)
                Text(cleaner?.name ?? "Nearest cleaner").lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var optionsSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            cleanerRow
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                ForEach(ServiceOption.all) { option in
                    optionRow(option)
                }
            }
            .padding(.horizontal, 16)

            Text(feeExplainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Button {
                Task { await book() }
            } label: {
                Text(submitting ? "Booking…" : "Book \(selected.name) · \(selected.priceCents.asMoney)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(submitting || cleaner == nil)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }

    /// The fee buys couriers, and which couriers depends on the tier. Under
    /// Pickup only the old single sentence promised a delivery time that tier
    /// does not pay for, which is the same lie the Orders screen used to tell
    /// once the clothes were ready.
    private var feeExplainer: String {
        let shop = cleaner?.name ?? "the shop"
        switch selected.id {
        case "pickup_only":
            return "Covers the courier to \(shop) only. You pay them for the cleaning and collect it from their counter when it's done."
        case "return_only":
            return "Covers the courier back to you only — you drop the bag at \(shop). You pay them for the cleaning, and pick a delivery time once it's ready."
        default:
            return "Covers pickup and delivery only. You pay \(shop) for the cleaning. They'll tell you when it's ready and you choose a delivery time."
        }
    }

    private var cleanerRow: some View {
        Button { choosingCleaner = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleaner?.name ?? "Choose a cleaner")
                        .font(.subheadline.weight(.semibold))
                    if let cleaner, let miles = cleaner.milesFrom(pickup.coordinate) {
                        Text(String(format: "%.1f mi away · %dh turnaround", miles, cleaner.turnaroundHours))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Tap to pick a partner shop")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Change")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cleaner: \(cleaner?.name ?? "none chosen"). Tap to change.")
    }

    private func optionRow(_ option: ServiceOption) -> some View {
        let isSelected = option.id == selected.id
        return Button {
            // A springy selection makes the tap feel answered even before the
            // price at the bottom updates.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { selected = option }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: option.symbol)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .background(isSelected ? Theme.accentSoft : Color(.tertiarySystemFill), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.name).font(.body.weight(.semibold))
                        if option.isRecommended {
                            Text("Best value")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(option.blurb).font(.footnote).foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(option.priceCents.asMoney)
                        .font(.body.weight(.semibold).monospacedDigit())
                    if let eta = option.pickupEtaMinutes {
                        Text("driver ~\(eta) min")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft.opacity(0.5) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Theme.accent : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func book() async {
        guard let cleaner, let userId = session.userId else { return }
        submitting = true
        error = nil
        defer { submitting = false }

        // A dismissed payment sheet leaves the draft row behind. Retrying the
        // same choice pays for that row rather than inserting another order —
        // otherwise every abandoned tap adds a near-identical draft to the
        // list and none of them can be told apart.
        if let draft, draft.tier == selected.id, draft.cleanerId == cleaner.id {
            await settle(orderId: draft.id)
            return
        }

        // Reuse a saved address when it is the same place. Inserting on every
        // booking piled up near-identical rows and made the saved list useless
        // after a handful of orders.
        let existing = store.addresses.first { $0.isSamePlace(as: pickup) }
        let saved: Address
        if let existing {
            saved = existing
        } else {
            // First address someone saves is almost always where they live, so
            // label it Home rather than "Pickup" — that label is what the
            // pinned row on the search screen shows.
            let label = store.addresses.isEmpty ? "Home" : nil
            guard let created = await store.addAddress(.init(
                user_id: userId,
                label: label,
                line1: pickup.line1,
                city: pickup.city,
                state: pickup.state,
                postal_code: pickup.postalCode,
                access_notes: accessNotes.isEmpty ? nil : accessNotes,
                lat: pickup.coordinate.latitude,
                lng: pickup.coordinate.longitude
            )) else {
                error = store.errorMessage ?? "Couldn't save that address."
                return
            }
            saved = created
        }

        let now = Date()
        // Priced at the tier the customer actually chose. Previously this was
        // always zero, so every booking was free — the screen promised a price
        // the order did not carry.
        guard let created = await store.createOrder(.init(
            customer_id: userId,
            cleaner_id: cleaner.id,
            address_id: saved.id,
            status: "draft",
            estimate_subtotal_cents: 0,
            delivery_fee_cents: selected.priceCents,
            service_tier: selected.id,
            pickup_window_start: now,
            pickup_window_end: now.addingTimeInterval(2 * 3600),
            customer_notes: nil
        )) else {
            error = store.errorMessage ?? "Couldn't book that pickup."
            return
        }

        // The order exists as a draft and becomes scheduled only once it is
        // paid for. An unpaid draft dispatches nobody.
        draft = Draft(id: created.id, tier: selected.id, cleanerId: cleaner.id)
        await settle(orderId: created.id)
    }

    /// Charge the courier fee and let the dispatcher decide what the order
    /// becomes.
    ///
    /// The server is what calls an order paid. This used to flip the row to
    /// `scheduled` from the phone the moment Stripe's sheet closed, which is
    /// how you get an order that looks scheduled to its owner and unpaid to
    /// everyone else — including the code that refuses to dispatch a courier
    /// for it.
    private func settle(orderId: UUID) async {
        guard let token = try? await store.accessToken() else {
            error = "Please sign in again."
            return
        }
        // The draft survives this screen; a payment sheet does not. Leave the
        // order to be paid from its own detail screen rather than putting a
        // sheet up over whatever the customer moved on to.
        guard isPresented else { return }

        let confirmation = await checkout.pay(orderId: orderId, accessToken: token)
        switch checkout.state {
        case .paid:
            // The dispatcher promoted the order and booked the courier before
            // it answered, so the list this returns to is already right.
            await store.loadOrders()
            // Unless it could not find one. The money moved either way, so
            // leaving on the success animation would hide a paid order that
            // nobody is coming for behind a list of finished ones.
            if let problem = confirmation?.problem {
                error = problem
            } else {
                // The only honest moment to ask. A driver is now coming, the
                // next thing that happens is hours away, and it happens with
                // the app closed — so the prompt needs no explaining. Awaited
                // before the dismiss, because a system alert raised into a
                // screen that is already going away can be dropped, and iOS
                // never offers that alert a second time.
                await PushRegistrar.shared.askAfterBooking()
                dismiss()
            }
        case let .failed(message):
            // A declined card used to close the sheet in total silence, which
            // reads as the app having lost the booking. Stay on the screen and
            // say what happened — the draft is still here to retry against.
            error = message
        case .idle, .working:
            break
        }
    }
}
