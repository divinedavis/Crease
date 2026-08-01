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
