import SwiftUI
import UIKit

/// The booking flow, one step at a time. Modelled as an enum rather than a
/// pile of booleans so two sheets can never be presented at once — the
/// failure that produces a half-dismissed screen with no way back.
enum BookingStep: Identifiable {
    // The intent rides along with every step rather than sitting in separate
    // state: a value read from the cover's content closure is the one the
    // step was created with, so the tile tapped on Home or Services is still
    // the one chosen when the booking screen opens.
    case address(BookingIntent)
    case pin(ResolvedAddress, BookingIntent)
    case book(ResolvedAddress, String, BookingIntent)
    case usual(UsualOrder)

    var id: String {
        switch self {
        case .address: "address"
        case .pin: "pin"
        case .book: "book"
        case .usual: "usual"
        }
    }
}

/// What the customer already said before the address step: a service tile, a
/// tier tile, or "Later" with a time. Carried through to the booking screen so
/// the tap that started the flow is not forgotten two screens later.
struct BookingIntent: Equatable {
    var kind: ServiceKind?
    var tierId: String?
    var when: Date?
}

enum AppTab: Hashable {
    case home, services, activity, account
}

/// The signed-in shell: four tabs along the bottom, the ride-hailing layout
/// (2026-10-08). The booking flow is owned here rather than by one tab, because
/// Home, Services and Activity all start it.
struct MainTabView: View {
    @EnvironmentObject private var store: OrderStore
    @ObservedObject private var router = PushRouter.shared

    @State private var tab: AppTab = .home
    @State private var flow: BookingStep?
    /// Owned here so a tapped notification can push a screen the customer
    /// never navigated to.
    @State private var activityPath: [Order] = []

    /// Worked out on the phone from this customer's own history.
    private var usual: UsualOrder? { UsualOrder.from(store.orders) }

    var body: some View {
        TabView(selection: $tab) {
            OrdersView(start: start, startSaved: startSaved, startUsual: startUsual)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            ServicesView(start: start)
                .tabItem { Label("Services", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.services)
            ActivityView(start: start, rebook: startUsual, path: $activityPath)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle.portrait.fill") }
                // Home no longer shows orders, so an order waiting on the
                // customer (approve a recount, pick a delivery time) is
                // flagged here instead.
                .badge(OrderLists(store.orders).attention.count)
                .tag(AppTab.activity)
            AccountView()
                .tabItem { Label("Account", systemImage: "person.fill") }
                .tag(AppTab.account)
        }
        .tint(Theme.ink)
        .fullScreenCover(item: $flow) { step in
            switch step {
            case let .address(intent):
                AddressEntryView(
                    onPicked: { resolved in
                        // Re-present as the next step rather than nesting,
                        // so Back always means one step, never "out".
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            flow = .pin(resolved, intent)
                        }
                    },
                    onPickedSaved: { saved in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            flow = .book(saved.asResolved, saved.accessNotes ?? "", intent)
                        }
                    }
                )
                // The address screen fades in over Home rather than sliding up
                // — it draws its own backdrop — so tapping the search bar reads
                // as the bar opening, not as a new screen arriving.
                .presentationBackground(.clear)
            case let .pin(resolved, intent):
                PinConfirmView(address: resolved) { confirmed, notes in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        flow = .book(confirmed, notes, intent)
                    }
                    flow = nil
                }
            case let .book(resolved, notes, intent):
                BookPickupView(pickup: resolved, accessNotes: notes, intent: intent)
            case let .usual(usual):
                BookPickupView(
                    pickup: usual.address.asResolved,
                    accessNotes: usual.address.accessNotes ?? "",
                    usual: usual
                )
            }
        }
        .task {
            await store.loadAll()
            await store.startWatching()
        }
        // No live socket while the app is in the background: iOS suspends it
        // anyway, and a socket left open keeps the radio awake on the way
        // there. Coming back reconnects and reloads once, which also picks up
        // whatever changed while it was away.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            Task { await store.stopWatching() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await store.loadOrders()
                await store.startWatching()
            }
        }
        .task(id: router.pendingOrderId) { await openTappedOrder() }
        // "Hey Siri, book my usual Crease pickup": open the booking prefilled.
        // Waits for the order history, which is what the usual is made from.
        .task(id: router.wantsUsual) {
            guard router.wantsUsual else { return }
            if store.orders.isEmpty { await store.loadOrders() }
            router.wantsUsual = false
            if let usual { flow = .usual(usual) } else { start() }
        }
    }

    /// Opens the address step without the cover's slide: the address screen
    /// animates itself in (see `presentationBackground` above).
    private func start(_ intent: BookingIntent = BookingIntent()) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { flow = .address(intent) }
    }

    /// A saved place tapped on Home skips the search, exactly as picking it on
    /// the address screen does.
    private func startSaved(_ address: Address, _ intent: BookingIntent) {
        flow = .book(address.asResolved, address.accessNotes ?? "", intent)
    }

    private func startUsual(_ usual: UsualOrder) {
        flow = .usual(usual)
    }

    /// A tapped notification names an order id; this screen needs the order.
    ///
    /// On a cold start the tap is delivered before anything has loaded, so the
    /// id waits here until there is a list to resolve it against — otherwise
    /// the notification that took someone straight to their order takes them
    /// to the list instead, exactly on the launch where it mattered.
    private func openTappedOrder() async {
        guard let id = router.pendingOrderId else { return }
        if store.orders.isEmpty { await store.loadOrders() }
        guard let order = store.orders.first(where: { $0.id == id }) else { return }
        router.pendingOrderId = nil
        tab = .activity
        if activityPath.last?.id != order.id { activityPath.append(order) }
    }
}
