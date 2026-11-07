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
                    Section {
                        VStack(alignment: .leading, spacing: 22) {
                            etaCard
                            serviceGrid
                            if let usual = UsualOrder.from(store.orders) {
                                UsualOrderCard(usual: usual) { startUsual(usual) }
                                    .staggeredAppear(0)
                            }
                            recents
                            PromoCard { showingArea = true }
                            forYou
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                    } header: {
                        searchBar
                    }
                }
            }
            .background(Theme.canvas)
            .navigationTitle("Crease")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The lowercase wordmark stands in for the title text; the
                // bar keeps its "Crease" title for VoiceOver and the tests.
                ToolbarItem(placement: .principal) {
                    Text("crease")
                        .font(.app(size: 26).weight(.heavy))
                        .kerning(-1.2)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel("Crease")
                }
            }
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

    /// The reference's hero: a courier on a white tile inside a grey card, and
    /// the one number people open the app for — how soon someone can come.
    private var etaCard: some View {
        let minutes = ServiceOption.recommended.pickupEtaMinutes ?? 30
        return Button { start(BookingIntent()) } label: {
            HStack(spacing: 16) {
                IllustrationTile(art: .courier, size: 92, fill: Theme.raised, inset: 0.08)
                VStack(alignment: .leading, spacing: 2) {
                    Text("~\(minutes) min")
                        .font(.app(size: 30).weight(.bold))
                        .kerning(-0.8)
                        .foregroundStyle(Theme.ink)
                    Text("A driver to your door")
                        .font(.app(.subheadline))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .softCard(padding: 16)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("A driver in about \(minutes) minutes. Book now")
    }

    /// What Crease does, as three illustrated tiles. Each one opens the
    /// booking with that service already chosen.
    private var serviceGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(ServiceKind.allCases.enumerated()), id: \.element.id) { i, kind in
                Button { start(BookingIntent(kind: kind)) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        kind.illustration.image
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 104)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        Text(kind.label)
                            .font(.app(.subheadline).weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(kind == .washFold ? "By the pound" : "Per item")
                            .font(.app(.caption))
                            .foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                // Not the bare service name: the booking sheet has its own
                // "Press only" button, and Home stays in the hierarchy
                // behind it.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Book \(kind.label)")
                .accessibilityAddTraits(.isButton)
                .staggeredAppear(i)
            }
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
                        .font(.app(.body).weight(.bold))
                        .foregroundStyle(Theme.glyph)
                    Text("Where from?")
                        .font(.app(.body).weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Book a pickup")

            Button { scheduling = true } label: {
                Label("Later", systemImage: "clock.fill")
                    .font(.app(.footnote).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.raised, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Schedule a pickup for later")
            .padding(.trailing, 8)
        }
        .frame(height: 56)
        .background(Theme.surface, in: Capsule())
        .padding(.horizontal, 20)
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
                        GlyphRow(
                            symbol: place.label == nil ? "clock.fill" : place.symbol,
                            title: place.label ?? place.line1,
                            subtitle: place.oneLine
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.app(.footnote).weight(.semibold))
                                .foregroundStyle(Theme.muted)
                                .padding(.top, 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Book from \(place.label ?? place.line1), \(place.oneLine)")
                    .staggeredAppear(i)
                    if i < places.count - 1 { Divider().overlay(Theme.line).padding(.leading, 44) }
                }
            }
        }
    }

    /// The booking tiers as illustrated cards, the "For you" row.
    private var forYou: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("For you")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(ServiceOption.all.enumerated()), id: \.element.id) { i, option in
                        Button { start(BookingIntent(tierId: option.id)) } label: {
                            OptionCard(option: option)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Book \(option.name), \(option.priceCents.asMoney). \(option.blurb)")
                        .staggeredAppear(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }
}

/// A delivery tier as a white card: illustration, name, price, and the
/// "Best value" tag where the arithmetic earns it.
struct OptionCard: View {
    let option: ServiceOption
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                IllustrationTile(art: option.illustration, size: width - 24, corner: 18)
                PlusBadge(size: 30).padding(6)
            }
            Text(option.name)
                .font(.app(.subheadline).weight(.semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Text(option.priceCents.asMoney)
                    .font(.app(.caption).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                if option.isRecommended {
                    Text("Best value")
                        .font(.app(.caption2).weight(.bold))
                        .foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.ink, in: Capsule())
                }
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1.5))
    }
}

/// The promo card: one fact worth knowing — where the couriers actually
/// reach. No invented discounts: there are none.
struct PromoCard: View {
    let onLearnMore: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IllustrationTile(art: .map, size: 76, fill: Theme.raised, inset: 0.1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pickups across Brooklyn")
                    .font(.app(.headline))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A courier collects within three miles of Fulton Street and brings it back clean.")
                    .font(.app(.footnote))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onLearnMore) {
                    Text("Learn more")
                        .font(.app(.footnote).weight(.semibold))
                        .foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.ink, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 2)
            }
        }
        .softCard(padding: 16)
    }
}

/// What "Learn more" opens: the service area, in words.
struct ServiceAreaSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label("Where we collect", systemImage: "mappin.and.ellipse")
                    .font(.app(.headline))
                Text(ServiceArea.blurb)
                    .font(.app(.body))
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
        let ready = order.needsReturnScheduling
        HStack(alignment: .center, spacing: 14) {
            IllustrationTile(art: ready ? .folded : .receipt, size: 56, fill: Theme.raised.opacity(ready ? 1 : 0.7), inset: 0.1)
            VStack(alignment: .leading, spacing: 4) {
                Label(ready ? "Ready — pick a delivery time" : "Needs your approval",
                      systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.app(.subheadline).weight(.semibold))
                    .foregroundStyle(ready ? Theme.accent : Theme.warn)

                Text(ready
                     ? "\(order.cleaner?.name ?? "The shop") has finished your order. Choose when you'd like it delivered."
                     : "\(order.cleaner?.name ?? "The cleaner") counted \(order.itemCount) items — \(order.displayCents.asMoney), \(order.overageReason)")
                    .font(.app(.footnote))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Tap to review")
                    .font(.app(.footnote).weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.app(.footnote).weight(.semibold))
                .foregroundStyle(Theme.muted)
        }
        .softCard(padding: 16, fill: ready ? Theme.surface : Theme.warnSoft)
    }
}

/// The live order: what's happening now, the journey, and who has the bag.
struct ActiveOrderCard: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                IllustrationTile(art: order.illustration, size: 68, fill: Theme.raised, inset: 0.08)
                VStack(alignment: .leading, spacing: 3) {
                    Text(order.statusTitle)
                        .font(.app(.title3).weight(.bold))
                        .foregroundStyle(Theme.ink)
                    if !order.statusDetail.isEmpty {
                        Text(order.statusDetail)
                            .font(.app(.subheadline))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.app(.footnote).weight(.semibold))
                    .foregroundStyle(Theme.muted)
            }

            JourneyTrack(order: order)

            Divider().overlay(Theme.line)

            if let leg = order.liveLeg, let courier = leg.courierName {
                HStack(spacing: 12) {
                    Image(systemName: "car.fill")
                        .foregroundStyle(Theme.glyph)
                        .frame(width: 24)
                    Text(courier + (leg.courierVehicle.map { " · \($0)" } ?? ""))
                        .font(.app(.subheadline).weight(.semibold))
                }
            }

            HStack {
                Text(order.cleaner?.name ?? "—")
                    .font(.app(.footnote))
                    .foregroundStyle(Theme.muted)
                Spacer()
                // No number until the shop has one. "$0.00 est." is not a
                // cheap order, it is the absence of a price rendered as money.
                if let price = order.priceText {
                    Text(price)
                        .font(.app(.footnote).weight(.semibold).monospacedDigit())
                    if order.isEstimate {
                        Text("est.")
                            .font(.app(.caption2))
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("Priced after counting")
                        .font(.app(.caption2))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .softCard()
    }
}

struct PastOrderRow: View {
    let order: Order

    var body: some View {
        HStack(spacing: 14) {
            IllustrationTile(art: .basket, size: 52, corner: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.cleaner?.name ?? "Order \(order.shortCode)")
                    .font(.app(.subheadline).weight(.semibold))
                Text(order.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.app(.caption))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            StatusPill(status: order.status)
            // A cancelled order never reached a counter, so it has no price and
            // an em dash is the honest column.
            Text(order.priceText ?? "—")
                .font(.app(.subheadline).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .softCard(padding: 12)
    }
}

/// The order this customer keeps placing, one tap from home.
struct UsualOrderCard: View {
    let usual: UsualOrder
    let onBook: () -> Void

    var body: some View {
        Button(action: onBook) {
            HStack(spacing: 14) {
                IllustrationTile(art: .repeat, size: 64, corner: 18, inset: 0.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your usual")
                        .font(.app(.headline))
                        .foregroundStyle(Theme.ink)
                    Text("\(usual.summary) at \(usual.cleanerName)")
                        .font(.app(.footnote))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                    if let day = usual.dayText {
                        Text("You usually book on \(day)")
                            .font(.app(.caption))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                PlusBadge(size: 38)
            }
            .outlineCard(padding: 12)
        }
        .buttonStyle(PressableStyle())
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
