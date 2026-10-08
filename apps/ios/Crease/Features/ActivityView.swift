import SwiftUI

/// Upcoming and past orders (the "Activity" tab, 2026-10-08).
///
/// Shaped like a ride app's trip history: what is coming up first, then the
/// last order large with its route on a map, then the rest as rows that can be
/// booked again in one tap.
struct ActivityView: View {
    @EnvironmentObject private var store: OrderStore

    let start: (BookingIntent) -> Void
    let rebook: (UsualOrder) -> Void

    @State private var path: [Order] = []

    var body: some View {
        let lists = OrderLists(store.orders)
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header("Upcoming")
                    if store.isLoading && store.orders.isEmpty {
                        skeleton
                    } else if lists.active.isEmpty {
                        noUpcoming
                    } else {
                        ForEach(Array(lists.active.enumerated()), id: \.element.id) { i, order in
                            NavigationLink(value: order) { ActiveOrderCard(order: order) }
                                .buttonStyle(PressableStyle())
                                .accessibilityIdentifier("order-card")
                                .staggeredAppear(i)
                        }
                    }

                    if !lists.past.isEmpty {
                        header("Past").padding(.top, 10)
                        if let latest = lists.past.first {
                            NavigationLink(value: latest) { LatestOrderCard(order: latest) }
                                .buttonStyle(PressableStyle())
                                .accessibilityIdentifier("order-card")
                                .staggeredAppear(1)
                        }
                        ForEach(Array(lists.past.dropFirst().enumerated()), id: \.element.id) { i, order in
                            HistoryRow(order: order, rebook: UsualOrder.rebook(order).map { usual in { rebook(usual) } })
                                .staggeredAppear(i + 2)
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("Activity")
            .navigationDestination(for: Order.self) { OrderDetailView(order: $0) }
            .refreshable { await store.loadOrders() }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }

    /// Placeholder rows while the first load is in flight, so the tab has a
    /// shape at once instead of a spinner on an empty page.
    private var skeleton: some View {
        VStack(spacing: 18) {
            ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
        }
        .transition(.opacity)
    }

    private var noUpcoming: some View {
        Button { start(BookingIntent()) } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You have no upcoming pickups")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Label("Book a pickup", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
            }
            .creaseCard()
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
    }
}

/// The most recent finished order, large, with its route drawn on a map.
private struct LatestOrderCard: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let address = order.address {
                RouteSnapshot(pickup: address.asResolved.coordinate, shop: order.cleaner?.coordinate, shopName: order.cleaner?.name)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text(order.cleaner?.name ?? "Order \(order.shortCode)")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            HStack {
                Text(order.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                StatusPill(status: order.status)
            }
            .font(.footnote)
            .foregroundStyle(Theme.muted)
            Text(order.priceText ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
        }
        .creaseCard()
    }
}

/// One past order as a row, with Rebook on the right when it can be repeated.
private struct HistoryRow: View {
    let order: Order
    let rebook: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            NavigationLink(value: order) {
                HStack(spacing: 14) {
                    Image(systemName: "bag.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 52, height: 52)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(order.cleaner?.name ?? "Order \(order.shortCode)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text(order.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(order.priceText ?? order.status.title)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)

            if let rebook {
                Button(action: rebook) {
                    Label("Rebook", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Rebook \(order.cleaner?.name ?? "this order")")
            }
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
