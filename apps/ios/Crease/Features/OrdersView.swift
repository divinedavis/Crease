import SwiftUI

/// Home.
///
/// The live order gets the whole top of the screen because it is the only
/// reason most people open this app. Everything else — history, scheduling —
/// is secondary to answering "where are my clothes" without a tap.
struct OrdersView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: OrderStore

    @State private var showingSchedule = false

    private var active: [Order] { store.orders.filter { $0.status.isActive } }
    private var past: [Order] { store.orders.filter { !$0.status.isActive } }
    private var needsAttention: [Order] {
        store.orders.filter { $0.status == .awaitingApproval }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(needsAttention) { order in
                        NavigationLink(value: order) {
                            ApprovalBanner(order: order)
                        }
                        .buttonStyle(.plain)
                    }

                    if active.isEmpty && store.orders.isEmpty && !store.isLoading {
                        EmptyState { showingSchedule = true }
                            .padding(.top, 60)
                    }

                    ForEach(active.filter { $0.status != .awaitingApproval }) { order in
                        NavigationLink(value: order) {
                            ActiveOrderCard(order: order)
                        }
                        .buttonStyle(.plain)
                    }

                    if !past.isEmpty {
                        HStack {
                            Text("Past orders")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 12)

                        ForEach(past) { order in
                            NavigationLink(value: order) {
                                PastOrderRow(order: order)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Crease")
            .navigationDestination(for: Order.self) { OrderDetailView(order: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", role: .destructive) {
                            Task { await session.signOut() }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingSchedule = true
                } label: {
                    Label("Schedule a pickup", systemImage: "bag.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .padding(16)
                .background(.bar)
            }
            .refreshable { await store.loadAll() }
            .sheet(isPresented: $showingSchedule) {
                SchedulePickupView()
            }
        }
        .task {
            await store.loadAll()
            await store.startWatching()
        }
    }
}

private struct ApprovalBanner: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs your approval", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warn)

            Text("\(order.cleaner?.name ?? "The cleaner") counted \(order.itemCount) items — \(order.displayCents.asMoney), above your \(order.estimateSubtotalCents.asMoney) estimate.")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Tap to review")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.warnSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

private struct ActiveOrderCard: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(order.status.title)
                        .font(.headline)
                    if !order.status.detail.isEmpty {
                        Text(order.status.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            JourneyTrack(status: order.status)

            if let leg = order.liveLeg, let courier = leg.courierName {
                HStack(spacing: 8) {
                    Image(systemName: "car.fill")
                        .foregroundStyle(Theme.accent)
                    Text(courier + (leg.courierVehicle.map { " · \($0)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(order.cleaner?.name ?? "—")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(order.displayCents.asMoney)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                if order.isEstimate {
                    Text("est.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .creaseCard()
    }
}

private struct PastOrderRow: View {
    let order: Order

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.cleaner?.name ?? "Order \(order.shortCode)")
                    .font(.subheadline.weight(.medium))
                Text(order.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(status: order.status)
            Text(order.displayCents.asMoney)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .creaseCard()
    }
}

private struct EmptyState: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bag")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No orders yet")
                .font(.headline)
            Text("Schedule a pickup and we'll collect your bag, get it cleaned, and bring it back.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}
