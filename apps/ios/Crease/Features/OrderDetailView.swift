import SwiftUI

/// Tracking and approval.
///
/// The approval decision is the one place in the app where the customer is
/// asked for money, so it shows the whole arithmetic — old estimate, new
/// count, itemised — before the button. Nobody should have to trust a single
/// number here.
struct OrderDetailView: View {
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss

    let order: Order
    @State private var approving = false
    @State private var confirmingCancel = false
    @State private var cancelling = false
    @State private var cancelError: String?
    @State private var schedulingReturn = false
    @StateObject private var checkout = Checkout()
    @State private var paying = false
    @State private var payError: String?

    /// Prefer the freshly-loaded copy so realtime updates land on this screen
    /// while it is open, rather than showing whatever was passed in.
    private var live: Order {
        store.orders.first { $0.id == order.id } ?? order
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                if let payError { payProblemCard(payError) }
                if live.status == .draft { unpaidCard }
                if live.needsReturnScheduling { readyCard }
                if live.awaitsCounterCollection { collectionCard }
                if live.awaitsCustomerDropOff { dropOffCard }
                if live.status == .awaitingApproval { approvalCard }
                if !live.finishedLegs.isEmpty { handoverCard(live.finishedLegs) }
                if let items = live.orderItems, !items.isEmpty { itemsCard(items) }
                detailsCard
                if let leg = live.liveLeg { courierCard(leg) }
                cancelSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Crease")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $schedulingReturn) {
            ScheduleReturnView(order: live)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(live.statusTitle)
                .font(.title3.weight(.semibold))
            if !live.statusDetail.isEmpty {
                Text(live.statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            JourneyTrack(order: live)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .creaseCard()
    }

    /// A booking whose card never went through.
    ///
    /// It is neither in progress nor history, and it accumulates: leaving it
    /// on the list as an unexplained "Draft" is how someone ends up with seven
    /// of them and no idea what they are. There are exactly two useful things
    /// to do with one, so offer both — this pays it, and the cancel section
    /// below already covers a draft.
    private var unpaidCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Payment not completed", systemImage: "creditcard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warn)

            Text("Nothing has been charged and no driver has been booked. Pay the \(live.deliveryFeeCents.asMoney) courier fee and we'll send one.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await payNow() }
            } label: {
                Text(paying ? "Opening payment…" : "Pay \(live.deliveryFeeCents.asMoney)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(paying)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.warnSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// What went wrong with a payment, kept outside `unpaidCard` on purpose.
    ///
    /// The worst outcome to report is the one where the charge succeeded and
    /// the dispatch did not: by then the order has left 'draft' and that card
    /// is gone, so anything nested inside it would vanish at exactly the
    /// moment there is most to say.
    private func payProblemCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.warnSoft)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// Pickup only ends at the shop's counter. Same "your clothes are ready"
    /// moment as `readyCard`, minus the delivery this tier never bought — so
    /// it says where the clothes are instead of asking when to bring them.
    private var collectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ready to collect", systemImage: "bag.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("\(live.cleaner?.name ?? "The shop") has finished. You booked pickup only, so collect it from their counter whenever suits — there's no delivery on this order.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let shop = live.cleaner, let street = shop.line1 {
                Text([street, shop.city, shop.state].joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// Return only starts at the shop's counter, and the customer is the one
    /// carrying the bag there — so the address is the whole point of this
    /// card. Nothing moves on this order until they make that trip.
    private var dropOffCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Drop your bag off", systemImage: "figure.walk")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("You booked the delivery home only, so take your bag to \(live.cleaner?.name ?? "the shop") whenever suits. They'll count it in and we'll bring it back when it's ready.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let shop = live.cleaner, let street = shop.line1 {
                Text([street, shop.city, shop.state].joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// The only screen state that asks the customer for something rather than
    /// telling them something.
    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your clothes are ready", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("\(live.cleaner?.name ?? "The shop") has finished. Choose when you'd like them delivered.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                schedulingReturn = true
            } label: {
                Text("Choose a delivery time").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Approve the updated total", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warn)

            Text("\(live.cleaner?.name ?? "The cleaner") counted more items than your estimate covered. Nothing has been charged beyond your original hold.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 7) {
                row("Your estimate", live.estimateSubtotalCents.asMoney, muted: true)
                row("Counted at the shop", (live.subtotalCents ?? 0).asMoney, muted: true)
                Divider()
                row("New total", live.displayCents.asMoney, bold: true)
            }

            Button {
                Task {
                    approving = true
                    if await store.approve(order: live) { dismiss() }
                    approving = false
                }
            } label: {
                Text(approving ? "Approving…" : "Approve \(live.displayCents.asMoney)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(approving)

            Text("Questions? Call \(live.cleaner?.name ?? "the shop") before approving.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.warnSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func itemsCard(_ items: [OrderItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What they counted")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(items) { item in
                HStack {
                    Text(item.label).font(.subheadline)
                    Text("×\(item.quantity)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.totalCents.asMoney)
                        .font(.subheadline.monospacedDigit())
                }
            }

            Divider()
            HStack {
                Text("Total").font(.subheadline.weight(.semibold))
                Spacer()
                Text(live.displayCents.asMoney)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .creaseCard()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The title used to carry this. It is the only handle the customer
            // can give the shop over the phone, so it moves here rather than
            // disappearing with the title.
            labelled("Order", live.shortCode)
            if let cleaner = live.cleaner {
                labelled("Cleaner", cleaner.name)
                callRow(cleaner)
            }
            labelled("Service", live.serviceTierName)
            if let address = live.address {
                labelled(live.addressLabel, address.oneLine)
            }
            // The one thing worth knowing while the bag is at the shop. Anchored
            // on when it arrived there, not on when it was booked, and absent
            // entirely until the server has a number — see `showsReadyEstimate`.
            if live.showsReadyEstimate, let window = live.readyWindowText {
                labelled("Ready by", window)
            }
            if let start = live.returnWindowStart, let end = live.returnWindowEnd {
                labelled(
                    "Delivery window",
                    "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
                )
            }
            // Every order carries a pickup window from booking, but nobody is
            // collecting a return-only one — showing it promises a driver the
            // tier never bought. It expires as information too: once the bag is
            // at the shop that window has already happened, and the customer
            // watched it happen. "Ready by" above is what they are asking.
            if !live.isReturnOnly, !live.hasReachedCleaner,
               let start = live.pickupWindowStart, let end = live.pickupWindowEnd {
                labelled(
                    "Pickup window",
                    "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
                )
            }
            if let notes = live.customerNotes, !notes.isEmpty {
                labelled("Your notes", notes)
            }
            if let notes = live.cleanerNotes, !notes.isEmpty {
                labelled("From the cleaner", notes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .creaseCard()
    }

    /// What already happened, stated in words.
    ///
    /// The courier card describes the live leg and vanishes the moment that
    /// leg ends, so a bag that was collected, driven across Brooklyn and
    /// handed over left nothing behind but a lit segment on the track. A
    /// delivery that worked should say so, with the time and the person who
    /// did it — and one that did not should say that even louder.
    private func handoverCard(_ legs: [DeliveryLeg]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(legs) { leg in
                ForEach(handoverRows(leg)) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.failed
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(row.failed ? Theme.warn : Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .creaseCard()
    }

    private struct HandoverRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        var failed = false
    }

    /// Up to two rows a leg: custody taken, custody given up.
    ///
    /// Both ends matter and they are different events — "collected 1:24" and
    /// "at the shop 1:41" is the difference between a driver holding your
    /// clothes and the shop holding them.
    private func handoverRows(_ leg: DeliveryLeg) -> [HandoverRow] {
        let shop = live.cleaner?.name ?? "the shop"
        var rows: [HandoverRow] = []

        if let taken = leg.pickedUpAt {
            rows.append(HandoverRow(
                id: "\(leg.id)-taken",
                title: leg.isPickup ? "Collected from you" : "Collected from \(shop)",
                detail: [stamp(taken), leg.courierName].compactMap { $0 }.joined(separator: " · ")
            ))
        }

        // A leg with no completion time is one the provider never closed out.
        // Inventing a row for it would claim a handover nobody recorded.
        guard let done = leg.completedAt else { return rows }

        if leg.didDeliver {
            rows.append(HandoverRow(
                id: "\(leg.id)-done",
                title: leg.isPickup ? "Dropped off at \(shop)" : "Delivered to you",
                detail: stamp(done)
            ))
        } else if leg.status == "cancelled" {
            rows.append(HandoverRow(
                id: "\(leg.id)-done",
                title: leg.isPickup ? "Pickup cancelled" : "Delivery cancelled",
                detail: stamp(done),
                failed: true
            ))
        } else {
            rows.append(HandoverRow(
                id: "\(leg.id)-done",
                title: leg.isPickup
                    ? "The driver couldn't collect your bag"
                    : "The driver couldn't deliver it — it's back at \(shop)",
                detail: stamp(done),
                failed: true
            ))
        }
        return rows
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func courierCard(_ leg: DeliveryLeg) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(leg.leg == "pickup" ? "Collecting from you" : "Bringing it back",
                  systemImage: "car.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)

            if let name = leg.courierName {
                Text(name + (leg.courierVehicle.map { " · \($0)" } ?? ""))
                    .font(.subheadline)
            }

            // Surfaced only when the carrier actually issued one; showing a
            // blank "code" slot on every order teaches people to ignore it.
            if let pin = leg.dropoffPincode {
                HStack(spacing: 8) {
                    Text("Handoff code")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(pin)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .tracking(3)
                }
                .padding(.top, 2)
            }

            if let url = leg.trackingURL {
                Link(destination: url) {
                    Label("Track the driver", systemImage: "map")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .creaseCard()
    }

    /// Cancellation, and an honest explanation when it is no longer possible.
    ///
    /// Shown rather than hidden once the bag is collected: "you cannot cancel"
    /// with a reason is a better answer than a screen with no cancel on it,
    /// which reads as the option being missing rather than gone.
    @ViewBuilder
    private var cancelSection: some View {
        if live.status.isCancellable {
            VStack(alignment: .leading, spacing: 10) {
                if let cancelError {
                    Text(cancelError)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(role: .destructive) {
                    confirmingCancel = true
                } label: {
                    Text(cancelling ? "Cancelling…" : "Cancel this pickup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(cancelling)

                if live.status.cancellationMayCost {
                    Text("A driver may already be on the way. If they have set off, the trip is still charged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            .confirmationDialog(
                "Cancel this pickup?",
                isPresented: $confirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel pickup", role: .destructive) {
                    Task { await performCancel() }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text(cancellationMoneyNote)
            }
        } else if live.status.isActive {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(cannotCancelReason)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                // No number here. This card tells the customer to call, and the
                // cleaner card directly above it is already showing the number
                // to call — repeating it reads as two different numbers at a
                // glance, which is worse than the dead end it was fixing.
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .creaseCard()
        }
    }

    /// The shop's number, dialable.
    ///
    /// Dropped whole when there is nothing to dial rather than rendered as
    /// dead text: an affordance that does nothing when tapped is worse than an
    /// absent one, because the customer keeps tapping it.
    @ViewBuilder
    private func callRow(_ cleaner: Cleaner) -> some View {
        if let number = cleaner.formattedPhone, let url = cleaner.callURL {
            Link(destination: url) {
                Label(number, systemImage: "phone.fill")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityLabel("Call \(cleaner.name) at \(number)")
        }
    }

    /// What cancelling does to the customer's money.
    ///
    /// The fee is taken at booking now, so the old single sentence — nothing
    /// collected, nothing charged — is only true of a draft. Everything past
    /// it has already been paid for, and a failed order is a charge with
    /// nothing whatsoever to show for it.
    private var cancellationMoneyNote: String {
        switch live.status {
        case .draft: "Nothing has been charged, so this costs you nothing."
        case .failed: "No driver was ever booked, so the courier fee comes back to you."
        case .pickupDispatched: "We'll stop the driver if we still can. If they've already set off, that trip is charged."
        default: "Nothing has been collected yet, so the courier fee comes back to you."
        }
    }

    private var cannotCancelReason: String {
        switch live.status {
        case .inTransitToCleaner:
            "Your bag is with a driver, so this can no longer be cancelled. Call \(live.cleaner?.name ?? "the shop") if something is wrong."
        case .atCleaner, .awaitingApproval:
            "Your bag is at the shop. Call \(live.cleaner?.name ?? "them") to sort anything out."
        case .cleaning:
            "Cleaning has started, so this can't be cancelled."
        default:
            "This order can no longer be cancelled."
        }
    }

    /// Finish a draft's payment. Stays on this screen either way: once the
    /// dispatcher promotes the order the reloaded copy drops the card and the
    /// customer watches it become a real booking, which is a better answer
    /// than being bounced back to a list.
    private func payNow() async {
        paying = true
        payError = nil
        defer { paying = false }

        guard let token = try? await store.accessToken() else {
            payError = "Please sign in again."
            return
        }
        let confirmation = await checkout.pay(orderId: live.id, accessToken: token)
        switch checkout.state {
        case .paid:
            await store.loadOrders()
            // Paid is not the same as dispatched. The reloaded order drops the
            // unpaid card, so without this the screen simply goes quiet on a
            // customer who is now owed either a courier or their money back.
            payError = confirmation?.problem
            // A draft finished here is a booking finished — same moment as the
            // booking screen, reached through the other door.
            if payError == nil { await PushRegistrar.shared.askAfterBooking() }
        case let .failed(message):
            // Reloaded on the way out too. The failures that matter here are
            // the ones after the charge, and the order has moved off 'draft'
            // by then — without this the unpaid card sits there insisting
            // nothing was charged, directly above the line saying it was.
            await store.loadOrders()
            payError = message
        case .idle, .working:
            break
        }
    }

    private func performCancel() async {
        cancelling = true
        cancelError = nil
        defer { cancelling = false }
        if let message = await store.cancel(order: live) {
            // Covers both a refused cancellation and a cancellation whose
            // refund is still pending. Either way the customer stays on the
            // screen and reads it rather than being returned to a list.
            cancelError = message
        } else {
            dismiss()
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String, muted: Bool = false, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(muted ? .secondary : .primary)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.bold).monospacedDigit()
                           : .subheadline.monospacedDigit())
                .foregroundStyle(muted ? .secondary : .primary)
        }
    }
}
