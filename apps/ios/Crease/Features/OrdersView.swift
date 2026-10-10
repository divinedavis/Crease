import SwiftUI

/// Home.
///
/// Laid out like a ride-hailing home screen (owner, 2026-10-08): one search bar
/// that pins to the top as the page scrolls, the places this customer books
/// from right under it, then everything else Crease does. Orders are not shown
/// here (owner, 2026-10-10): they live on the Activity tab, which carries a
/// badge when one needs the customer.
struct OrdersView: View {
    @EnvironmentObject private var store: OrderStore

    let start: (BookingIntent) -> Void
    let startSaved: (Address, BookingIntent) -> Void
    let startUsual: (UsualOrder) -> Void

    @State private var scheduling = false
    @State private var laterTime: Date?
    @State private var showingArea = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    serviceStrip
                        .padding(.bottom, 6)

                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            recents

                            if let usual = UsualOrder.from(store.orders) {
                                UsualOrderCard(usual: usual) { startUsual(usual) }
                                    .staggeredAppear(0)
                            }

                            PromoCard { showingArea = true }
                                .padding(.top, 4)

                            forYou
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    } header: {
                        searchBar
                    }
                }
            }
            .background(Theme.canvas)
            .navigationTitle("Crease")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.loadAll() }
            .sheet(isPresented: $scheduling, onDismiss: {
                // "Later" is a time first and an address second, like the
                // ride apps: the time is asked here, then the usual flow.
                if let laterTime {
                    self.laterTime = nil
                    start(BookingIntent(when: laterTime))
                }
            }) {
                SchedulePickupView(title: "Pickup time", earliest: Date().addingTimeInterval(3600), chosen: $laterTime)
                    .presentationDetents([.height(260)])
            }
            .sheet(isPresented: $showingArea) {
                ServiceAreaSheet()
                    .presentationDetents([.medium])
            }
            .task { if store.addresses.isEmpty { await store.loadAddresses() } }
        }
    }

    /// The top strip: what Crease does, as tabs-that-are-shortcuts. Each one
    /// opens the booking with that service already chosen.
    private var serviceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(ServiceKind.allCases) { kind in
                    Button { start(BookingIntent(kind: kind)) } label: {
                        Label(kind.label, systemImage: kind.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    // Not the bare service name: the booking sheet has its own
                    // "Press only" button, and Home stays in the hierarchy
                    // behind it.
                    .accessibilityLabel("Book \(kind.label)")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Looks like a text field, behaves like a button, and pins to the top
    /// once the page scrolls under it. Tapping opens the address screen with
    /// the keyboard already up.
    private var searchBar: some View {
        HStack(spacing: 0) {
            Button { start(BookingIntent()) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.bold))
                    Text("Where from?")
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.ink)
                .padding(.leading, 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Book a pickup")

            Button { scheduling = true } label: {
                Label("Later", systemImage: "calendar")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.canvas, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Schedule a pickup for later")
            .padding(.trailing, 8)
        }
        .frame(height: 52)
        .background(Theme.surface, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.canvas)
    }

    /// Saved places, newest first, two at most: the right answer is nearly
    /// always one of them, and a tap books straight from it.
    @ViewBuilder private var recents: some View {
        let places = Array(store.addresses.prefix(2))
        if !places.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(places.enumerated()), id: \.element.id) { i, place in
                    Button { startSaved(place, BookingIntent()) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: place.label == nil ? "clock.fill" : place.symbol)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .frame(width: 36, height: 36)
                                .background(Theme.surface, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.label ?? place.line1)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(place.oneLine)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Book from \(place.label ?? place.line1), \(place.oneLine)")
                    .staggeredAppear(i)
                    if i < places.count - 1 { Divider().padding(.leading, 50) }
                }
            }
        }
    }

    /// The booking tiers as square tiles, the "For you" row.
    private var forYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For you")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(ServiceOption.all.enumerated()), id: \.element.id) { i, option in
                        Button { start(BookingIntent(tierId: option.id)) } label: {
                            ServiceTile(
                                title: option.name,
                                symbol: option.symbol,
                                badge: option.isRecommended ? "Best value" : nil
                            )
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Book \(option.name), \(option.priceCents.asMoney). \(option.blurb)")
                        .staggeredAppear(i)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// A square service tile with an optional red tag on its corner.
struct ServiceTile: View {
    let title: String
    let symbol: String
    var badge: String? = nil
    var size: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size * 0.82)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.tag, in: Capsule())
                            .offset(x: -4, y: -6)
                    }
                }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: size)
        }
    }
}

/// The promo card: navy, illustrated, one fact worth knowing — where the
/// couriers actually reach. No invented discounts: there are none.
struct PromoCard: View {
    let onLearnMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pickups across Brooklyn")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A courier collects within three miles of Fulton Street and brings it back clean.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onLearnMore) {
                    Text("Learn more")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 4)
            }
            .padding(16)
            Spacer(minLength: 0)
            ZStack {
                // Still, like a ride app's promo art. A forever-animation here
                // kept Home redrawing for nothing, including under the address
                // screen, which is drawn over Home.
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 120, height: 120)
                Image(systemName: "hanger")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: 120)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Theme.promo, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// What "Learn more" opens: the service area, in words.
struct ServiceAreaSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label("Where we collect", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Text(ServiceArea.blurb)
                    .font(.body)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Service area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ApprovalBanner: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(order.needsReturnScheduling ? "Ready — pick a delivery time" : "Needs your approval",
                  systemImage: order.needsReturnScheduling ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(order.needsReturnScheduling ? Theme.accent : Theme.warn)

            Text(order.needsReturnScheduling
                 ? "\(order.cleaner?.name ?? "The shop") has finished your order. Choose when you'd like it delivered."
                 : "\(order.cleaner?.name ?? "The cleaner") counted \(order.itemCount) items — \(order.displayCents.asMoney), \(order.overageReason)")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Tap to review")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(order.needsReturnScheduling ? Theme.accentSoft : Theme.warnSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct ActiveOrderCard: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(order.statusTitle)
                        .font(.headline)
                    if !order.statusDetail.isEmpty {
                        Text(order.statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
            }

            JourneyTrack(order: order)

            if let leg = order.liveLeg, let courier = leg.courierName {
                HStack(spacing: 8) {
                    Image(systemName: "car.fill")
                        .foregroundStyle(Theme.accent)
                    Text(courier + (leg.courierVehicle.map { " · \($0)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }

            HStack {
                Text(order.cleaner?.name ?? "—")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                Spacer()
                // No number until the shop has one. "$0.00 est." is not a
                // cheap order, it is the absence of a price rendered as money.
                if let price = order.priceText {
                    Text(price)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    if order.isEstimate {
                        Text("est.")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("Priced after counting")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .creaseCard()
    }
}

struct PastOrderRow: View {
    let order: Order

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.cleaner?.name ?? "Order \(order.shortCode)")
                    .font(.subheadline.weight(.medium))
                Text(order.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            StatusPill(status: order.status)
            // A cancelled order never reached a counter, so it has no price and
            // an em dash is the honest column.
            Text(order.priceText ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .creaseCard()
    }
}

/// The order this customer keeps placing, one tap from home.
struct UsualOrderCard: View {
    let usual: UsualOrder
    let onBook: () -> Void

    var body: some View {
        Button(action: onBook) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your usual")
                        .font(.subheadline.weight(.semibold))
                    Text("\(usual.summary) at \(usual.cleanerName)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                    if let day = usual.dayText {
                        Text("You usually book on \(day)")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                Text("Book")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your usual: \(usual.summary) at \(usual.cleanerName). Book it again.")
        .accessibilityIdentifier("usual-order")
    }
}


/// The Activity tab's sections, split from the order list in one pass per
/// redraw instead of re-filtering it for each section (and a contains() per
/// row inside one of them).
struct OrderLists {
    let attention: [Order]
    let active: [Order]
    let activeOther: [Order]
    let past: [Order]

    init(_ orders: [Order]) {
        var attention: [Order] = [], active: [Order] = [], other: [Order] = [], past: [Order] = []
        for order in orders {
            let needs = order.status == .awaitingApproval || order.needsReturnScheduling
            if needs { attention.append(order) }
            if order.status.isActive {
                active.append(order)
                if !needs { other.append(order) }
            } else {
                past.append(order)
            }
        }
        self.attention = attention
        self.active = active
        self.activeOther = other
        self.past = past
    }
}
