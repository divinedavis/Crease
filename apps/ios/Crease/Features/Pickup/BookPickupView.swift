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
    /// Set when the server priced this route above the published fee. Nothing
    /// has been charged at that point — it is a question, and the answer either
    /// pays the real price or leaves the draft alone.
    @State private var repricedTo: (orderId: UUID, serviceTier: String, cents: Int)?
    /// How many pieces are going in the bag, 0 meaning "didn't count".
    /// Optional on purpose: nobody should have to count socks to book a
    /// courier, but a number given here is what the shop checks the bag
    /// against at the counter — the earliest a garment lost in transit can
    /// be noticed.
    @State private var itemCount = 0
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
            VStack(spacing: 10) {
                header
                // Anchored to the top, not appended to the options sheet: the
                // payment sheet covers the bottom of the screen by an amount
                // only Stripe decides (it grows with each wallet row it
                // offers), so anything bottom-anchored is behind it exactly
                // when it needs to be read. The top is the one band that
                // cannot be covered.
                if submitting, let cleaner {
                    reviewCard(cleaner: cleaner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: submitting)
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
        // A route outside the flat-rate courier band costs more to drive than
        // the published fee collects. The customer gets the real number and a
        // choice, rather than a card charge that does not match the button they
        // tapped. Declining leaves the draft to be paid — or abandoned — later.
        .alert(
            "This trip costs more",
            isPresented: Binding(
                get: { repricedTo != nil },
                set: { if !$0 { repricedTo = nil } }
            ),
            presenting: repricedTo
        ) { priced in
            Button("Pay \(priced.cents.asMoney)") {
                repricedTo = nil
                Task {
                    await settle(
                        orderId: priced.orderId,
                        serviceTier: priced.serviceTier,
                        agreedCents: priced.cents
                    )
                }
            }
            Button("Cancel", role: .cancel) { repricedTo = nil }
        } message: { priced in
            Text(
                "\(cleaner?.name ?? "This shop") is farther than our standard rate covers, so this trip is \(priced.cents.asMoney) instead of \(selected.priceCents.asMoney). Nothing has been charged."
            )
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

    /// What the customer is about to be charged for, shown while the payment
    /// sheet is up.
    ///
    /// Stripe's sheet has no room for it — there is no supported way to put
    /// custom content inside PaymentSheet — and what showed through behind it
    /// was the tier list, still offering the two options they had just chosen
    /// between. So the screen underneath becomes the receipt: the shop, where
    /// it is going, when a driver arrives, and what the number on the Pay
    /// button actually buys.
    private func reviewCard(cleaner: Cleaner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review your order")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(cleaner.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(turnaroundLine(for: cleaner))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            reviewRow(
                symbol: "mappin.and.ellipse",
                title: selected.legs == 1 && selected.id == "return_only"
                    ? "Deliver to \(pickup.line1)"
                    : "Collect from \(pickup.line1)",
                detail: etaLine
            )

            reviewRow(
                symbol: selected.symbol,
                title: selected.name,
                detail: itemCount > 0
                    ? "\(itemCount) item\(itemCount == 1 ? "" : "s") · \(selected.blurb)"
                    : selected.blurb
            )

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Courier fee")
                        .font(.subheadline.weight(.medium))
                    // Restating this here matters more than anywhere else on
                    // the screen: it is the last thing seen before a card is
                    // charged, and the one number people would otherwise
                    // mistake for the price of the cleaning.
                    Text("Cleaning billed separately by the shop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(selected.priceCents.asMoney)
                    .font(.title3.weight(.semibold))
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private func reviewRow(symbol: String, title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func turnaroundLine(for cleaner: Cleaner) -> String {
        if let miles = cleaner.milesFrom(pickup.coordinate) {
            return String(format: "%.1f mi away · %dh turnaround", miles, cleaner.turnaroundHours)
        }
        return "\(cleaner.turnaroundHours)h turnaround"
    }

    /// Only the driver's arrival is quotable at booking, and only on the tiers
    /// that actually send one to the customer — the same rule the tier rows
    /// follow. Inventing a whole-order ETA here would be the one promise this
    /// screen has never made.
    private var etaLine: String? {
        guard let minutes = selected.pickupEtaMinutes else { return nil }
        return "Driver arrives in about \(minutes) min"
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

            if submitting {
                // The review above is now saying all of this, and the live
                // controls under a payment sheet are worse than redundant: a
                // "Change" chevron next to a card being charged offers
                // something the screen cannot honour.
                payingPlaceholder
            } else {
                bookingControls
            }
        }
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }

    private var payingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Completing your booking…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 28)
    }

    @ViewBuilder private var bookingControls: some View {
        Group {
            cleanerRow
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                ForEach(ServiceOption.all) { option in
                    optionRow(option)
                }
            }
            .padding(.horizontal, 16)

            itemCountRow
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Text(feeExplainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Button {
                Task { await book() }
            } label: {
                // No "Booking…" state here any more: these controls are
                // replaced wholesale while a booking is in flight.
                Text("Book \(selected.name) · \(selected.priceCents.asMoney)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(cleaner == nil)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
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

    /// Costs nothing and promises nothing — it just writes down the number so
    /// the shop can check the same one at the counter.
    private var itemCountRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "tshirt")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Items in the bag")
                    .font(.subheadline.weight(.medium))
                Text(itemCount == 0 ? "Optional — helps track your garments" : "The cleaner will confirm this count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(
                itemCount == 0 ? "—" : "\(itemCount)",
                value: $itemCount,
                in: 0...200
            )
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .fixedSize()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Items in the bag: \(itemCount == 0 ? "not counted" : String(itemCount)). Optional.")
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
            // The count is the one field the customer can revise between
            // attempts, so the retry carries whatever the stepper says now —
            // including nothing.
            await store.setCustomerItemCount(orderId: draft.id, count: itemCount > 0 ? itemCount : nil)
            await settle(orderId: draft.id, serviceTier: draft.tier, agreedCents: selected.priceCents)
            return
        }

        // The choice changed, so the draft on this screen is superseded — and
        // it may already own a live PaymentIntent from an abandoned sheet.
        // Cancel it before booking the replacement: the row cannot be reused
        // at a new price (the intent is minted once per order and Stripe
        // returns the original amount on a retry), so left alone it is an
        // uncollected hold on the customer's card next to an order they are
        // no longer buying.
        if let superseded = draft {
            await store.discardDraft(orderId: superseded.id)
            draft = nil
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
            customer_notes: nil,
            customer_item_count: itemCount > 0 ? itemCount : nil
        )) else {
            error = store.errorMessage ?? "Couldn't book that pickup."
            return
        }

        // The order exists as a draft and becomes scheduled only once it is
        // paid for. An unpaid draft dispatches nobody.
        draft = Draft(id: created.id, tier: selected.id, cleanerId: cleaner.id)
        await settle(orderId: created.id, serviceTier: selected.id, agreedCents: selected.priceCents)
    }

    /// Charge the courier fee and let the dispatcher decide what the order
    /// becomes.
    ///
    /// The server is what calls an order paid. This used to flip the row to
    /// `scheduled` from the phone the moment Stripe's sheet closed, which is
    /// how you get an order that looks scheduled to its owner and unpaid to
    /// everyone else — including the code that refuses to dispatch a courier
    /// for it.
    /// The tier travels with the order id rather than being read off
    /// `selected`, because it is what the dispatcher's answer has to be judged
    /// against: a booking with no courier is normal for return-only and a
    /// silent failure for everything else, and the row being settled is not
    /// always the choice currently highlighted on screen.
    private func settle(orderId: UUID, serviceTier: String, agreedCents: Int) async {
        guard let token = try? await store.accessToken() else {
            error = "Please sign in again."
            return
        }
        // The draft survives this screen; a payment sheet does not. Leave the
        // order to be paid from its own detail screen rather than putting a
        // sheet up over whatever the customer moved on to.
        guard isPresented else { return }

        let confirmation = await checkout.pay(
            orderId: orderId,
            accessToken: token,
            agreedCents: agreedCents
        )
        switch checkout.state {
        case .paid:
            // The dispatcher promoted the order and booked the courier before
            // it answered, so the list this returns to is already right.
            await store.loadOrders()
            // Unless it could not find one. The money moved either way, so
            // leaving on the success animation would hide a paid order that
            // nobody is coming for behind a list of finished ones.
            if let problem = confirmation?.problem(serviceTier: serviceTier) {
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
        case let .repriced(cents):
            // Nothing was charged and the draft is intact. Ask, then pay the
            // real price if they accept — a farther shop costs more to reach,
            // and quietly charging the difference is not an option.
            repricedTo = (orderId: orderId, serviceTier: serviceTier, cents: cents)
        case .idle, .working:
            break
        }
    }
}
