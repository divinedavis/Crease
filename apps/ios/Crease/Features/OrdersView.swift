import SwiftUI

/// Home.
///
/// One screen, no scrolling (owner, 2026-11-22): the customer's usual when
/// they have one and where Crease reaches at the top; the three services and
/// the search bar at the bottom, above the tab bar (owner, 2026-11-23). The driver-ETA card, the saved-place rows and the "For you" tier
/// row were removed that day; saved places are still one tap away on the
/// address screen, and tiers are chosen in the booking sheet. Orders are not
/// shown here (owner, 2026-10-10): they live on the Activity tab, which
/// carries a badge when one needs the customer.
struct OrdersView: View {
    @EnvironmentObject private var store: OrderStore

    let start: (BookingIntent) -> Void
    let startUsual: (UsualOrder) -> Void

    @State private var scheduling = false
    @State private var laterTime: Date?
    @State private var showingArea = false
    /// Home parting around the search bar as the address screen opens (owner's
    /// pick, "Part", 2026-11-23): the top slides up and away, the services drop,
    /// and the bar itself rises to where the address field will be and takes
    /// its look. The address screen opens only once the bar has landed, with
    /// its field in exactly that spot. All of it happens here, on Home: a
    /// screen being presented freezes the one behind it, and the keyboard's
    /// safe area pulls a flying view apart.
    @State private var parting = false
    /// The bar handed to its drawn copy (instantly), then landed (animated).
    @State private var flying = false
    @State private var landed = false
    /// How far the bar rises, fixed at the tap so its own movement never feeds back.
    @State private var flightRise: CGFloat = 0
    @State private var searchFrame: CGRect?
    @State private var contentTop: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            // Fits on one screen at every normal text size. At the largest
            // accessibility sizes it cannot, and clipping a button off the
            // bottom would hide it, so only then does the page scroll.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Where content starts under the bar; the address screen's
            // content starts at the same place, so its field can be found
            // from here before it has ever been opened.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { contentTop = $0 }
            .background(Theme.canvas)
            .navigationTitle("Crease")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The lowercase wordmark stands in for the title text; the
                // bar keeps its "Crease" title for VoiceOver and the tests.
                ToolbarItem(placement: .principal) {
                    WordmarkText(size: 28, relativeTo: .title2, isSplashTarget: true)
                        .foregroundStyle(Theme.ink)
                        .opacity(parting ? 0 : 1)
                        .animation(Self.partCurve, value: parting)
                        .accessibilityAddTraits(.isHeader)
                }
            }
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
        }
    }

    /// The search bar and the service row sit at the bottom, directly above
    /// the tab bar, where the thumb already is (owner, 2026-11-23). The usual
    /// order and the promo card take the top; the space between them grows.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                if let usual = UsualOrder.from(store.orders) {
                    UsualOrderCard(usual: usual) { startUsual(usual) }
                        .staggeredAppear(0)
                }
                PromoCard { showingArea = true }
            }
            .padding(.horizontal, 20)
            .offset(y: parting ? -140 : 0)
            .opacity(parting ? 0 : 1)
            .animation(Self.partCurve, value: parting)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 14) {
                searchBar
                    .zIndex(1)   // over the promo as it passes it
                serviceGrid
                    .padding(.horizontal, 20)
                    .offset(y: parting ? 280 : 0)
                    .opacity(parting ? 0 : 1)
                    .animation(Self.partCurve, value: parting)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
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
                .accessibilityLabel("Book \(kind.label)")
                .staggeredAppear(i)
            }
        }
    }

    /// The bar rises into the address field's place while Home parts around
    /// it, then the address screen opens over it. Reduce Motion, or a bar not
    /// yet measured, opens the screen with its plain fade.
    private func openSearch() {
        guard !flying else { return }   // a second tap mid-rise
        guard !reduceMotion, let searchFrame else { return start(BookingIntent()) }
        flightRise = SearchFlight.shared.fieldFrame(below: searchFrame, contentTop: contentTop).midY - searchFrame.midY
        // Each part carries its own animation (the .animation modifiers) so
        // the parting and the rise keep their own curves.
        flying = true
        parting = true
        Task {
            // The copy is on screen at the bar's spot before it is told to rise.
            await Task.yield()
            landed = true
            // Asked for only once the bar is home: presenting the address
            // screen freezes Home where it is, so asking mid-rise stranded
            // the bar short of the field. The rise ends crisply (no long
            // tail) so the pause before the page is brief.
            try? await Task.sleep(for: .milliseconds(400))
            SearchFlight.shared.landedAt = .now
            start(BookingIntent())
            // Whole again under the address screen, for when the customer
            // comes back. It has faded in over Home by then.
            try? await Task.sleep(for: .milliseconds(600))
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { parting = false; landed = false; flying = false }
        }
    }

    static let partCurve = Animation.timingCurve(0.5, 0, 0.7, 1, duration: 0.4)
    static let riseCurve = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.42)

    /// Looks like a text field, behaves like a button. Tapping opens the
    /// address screen with the keyboard already up.
    private var searchBar: some View {
        HStack(spacing: 0) {
            Button { openSearch() } label: {
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { searchFrame = $0 }
        // In flight the bar is a plain drawing of itself: a Button animates
        // its label apart from the capsule around it, so the text outran it.
        .opacity(flying ? 0 : 1)
        .overlay {
            if flying {
                FlyingSearchBar(landed: landed)
                    .frame(height: landed ? SearchFlight.fieldHeight : 56)
                    .offset(y: landed ? flightRise : 0)
                    .animation(Self.riseCurve, value: landed)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.canvas)
    }
}

/// Home's search bar as it rises and turns into the address field: the
/// capsule tightens to the field's corners and gains its outline, the
/// magnifier becomes the trip-start dot, the text dims to a placeholder, and
/// "Later" falls away. Shapes and text only, so it all moves as one.
struct FlyingSearchBar: View {
    let landed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: landed ? 20 : 28, style: .continuous)
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .font(.app(.body).weight(.bold))
                    .foregroundStyle(Theme.glyph)
                    .opacity(landed ? 0 : 1)
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().fill(Theme.canvas).frame(width: 4, height: 4))
                    .opacity(landed ? 1 : 0)
            }
            .frame(width: landed ? 10 : 20)
            // Two fixed colours crossfading: a Text whose colour changes
            // animates its glyphs on their own and ran ahead of the capsule.
            ZStack(alignment: .leading) {
                Text("Where from?").foregroundStyle(Theme.ink).opacity(landed ? 0 : 1)
                Text("Where from?").foregroundStyle(Color(.placeholderText)).opacity(landed ? 1 : 0)
            }
            .font(.app(.body).weight(.semibold))
            .lineLimit(1)
            Spacer(minLength: 0)
            Label("Later", systemImage: "clock.fill")
                .font(.app(.footnote).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.raised, in: Capsule())
                .scaleEffect(landed ? 0.8 : 1)
                .opacity(landed ? 0 : 1)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.ink.opacity(landed ? 1 : 0), lineWidth: 2))
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
