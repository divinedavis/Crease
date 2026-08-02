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

    /// Prefer the freshly-loaded copy so realtime updates land on this screen
    /// while it is open, rather than showing whatever was passed in.
    private var live: Order {
        store.orders.first { $0.id == order.id } ?? order
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                if live.status == .awaitingApproval { approvalCard }
                if let items = live.orderItems, !items.isEmpty { itemsCard(items) }
                detailsCard
                if let leg = live.liveLeg { courierCard(leg) }
                cancelSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(live.shortCode)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(live.status.title)
                .font(.title3.weight(.semibold))
            if !live.status.detail.isEmpty {
                Text(live.status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            JourneyTrack(status: live.status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .creaseCard()
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
            if let cleaner = live.cleaner {
                labelled("Cleaner", cleaner.name)
            }
            if let address = live.address {
                labelled("Pickup & delivery", address.oneLine)
            }
            if let start = live.pickupWindowStart, let end = live.pickupWindowEnd {
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

            if let urlString = leg.trackingUrl, let url = URL(string: urlString) {
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
                Text(live.status.cancellationMayCost
                     ? "We'll stop the driver if we still can. If they've already set off, that trip is charged."
                     : "Nothing has been collected yet, so you won't be charged.")
            }
        } else if live.status.isActive {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(cannotCancelReason)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .creaseCard()
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
