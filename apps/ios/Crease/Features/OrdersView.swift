import SwiftUI

/// Home.
///
/// The live order gets the whole top of the screen because it is the only
/// reason most people open this app. Everything else — history, scheduling —
/// is secondary to answering "where are my clothes" without a tap.
struct OrdersView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: OrderStore
    @EnvironmentObject private var lock: AppLock

    @State private var flow: BookingStep?
    /// Owned here so a tapped notification can push a screen the customer
    /// never navigated to.
    @State private var path: [Order] = []
    @ObservedObject private var router = PushRouter.shared

    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    @State private var exporting = false
    @State private var exportFile: ExportFile?
    // Held separately so it can be deleted in the sheet's onDismiss: the item
    // binding is already nil by the time that fires.
    @State private var lastExportURL: URL?
    @State private var exportError: String?

    /// The finished export, identified by where it was written so the sheet
    /// presents once per file rather than once per tap.
    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    /// The booking flow, one step at a time. Modelled as an enum rather than a
    /// pile of booleans so two sheets can never be presented at once — the
    /// failure that produces a half-dismissed screen with no way back.
    enum BookingStep: Identifiable {
        case address
        case pin(ResolvedAddress)
        case book(ResolvedAddress, String)
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

    /// Worked out on the phone from this customer's own history.
    private var usual: UsualOrder? { UsualOrder.from(store.orders) }

    var body: some View {
        let lists = OrderLists(store.orders)
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    greeting
                    searchEntry

                    if let usual = lists.usual {
                        UsualOrderCard(usual: usual) { flow = .usual(usual) }
                    }

                    ForEach(lists.attention) { order in
                        NavigationLink(value: order) {
                            ApprovalBanner(order: order)
                        }
                        .buttonStyle(.plain)
                    }

                    if lists.active.isEmpty && store.orders.isEmpty && !store.isLoading {
                        EmptyState()
                            .padding(.top, 40)
                    }

                    ForEach(lists.activeOther) { order in
                        NavigationLink(value: order) {
                            ActiveOrderCard(order: order)
                        }
                        .buttonStyle(.plain)
                    }

                    if !lists.past.isEmpty {
                        HStack {
                            Text("Past orders")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                            Spacer()
                        }
                        .padding(.top, 12)

                        ForEach(lists.past) { order in
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
                        if lock.biometry != .none {
                            Button {
                                Task { await lock.setEnabled(!lock.isEnabled) }
                            } label: {
                                Label(
                                    lock.isEnabled
                                        ? "Turn off \(lock.biometry.label) lock"
                                        : "Lock with \(lock.biometry.label)",
                                    systemImage: lock.isEnabled ? "lock.open" : "lock"
                                )
                            }
                        }
                        // The other half of "delete my account": people are
                        // entitled to a copy of what we hold on them, and it
                        // is all readable under their own session anyway.
                        Button {
                            Task { await performExport() }
                        } label: {
                            Label(
                                exporting ? "Preparing…" : "Download my data",
                                systemImage: "square.and.arrow.down"
                            )
                        }
                        .disabled(exporting)
                        Button("Sign out", role: .destructive) {
                            Task { await session.signOut() }
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label(deleting ? "Deleting…" : "Delete account", systemImage: "trash")
                        }
                        .disabled(deleting)
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
            // Deleting is irreversible and takes the order history with it, so
            // it is asked for twice: once to open this, once to confirm. Apple
            // requires the confirmation, and so does anyone who has fat-fingered
            // a menu.
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Keep my account", role: .cancel) {}
            } message: {
                Text(
                    "This permanently deletes your orders, saved addresses and account details. It cannot be undone."
                )
            }
            .alert(
                "Account not deleted",
                isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
            ) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .sheet(item: $exportFile, onDismiss: {
                // The share sheet is done: delete the PII export rather than
                // leaving it in tmp for iOS to purge whenever it chooses.
                if let url = lastExportURL {
                    try? FileManager.default.removeItem(at: url)
                    lastExportURL = nil
                }
            }) { file in
                ShareSheet(url: file.url)
            }
            .alert(
                "Couldn't prepare your data",
                isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .refreshable { await store.loadAll() }
            .fullScreenCover(item: $flow) { step in
                switch step {
                case .address:
                    AddressEntryView(
                        onPicked: { resolved in
                            // Re-present as the next step rather than nesting,
                            // so Back always means one step, never "out".
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                flow = .pin(resolved)
                            }
                        },
                        onPickedSaved: { saved in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                flow = .book(saved.asResolved, saved.accessNotes ?? "")
                            }
                        }
                    )
                case let .pin(resolved):
                    PinConfirmView(address: resolved) { confirmed, notes in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            flow = .book(confirmed, notes)
                        }
                        flow = nil
                    }
                case let .book(resolved, notes):
                    BookPickupView(pickup: resolved, accessNotes: notes)
                case let .usual(usual):
                    BookPickupView(
                        pickup: usual.address.asResolved,
                        accessNotes: usual.address.accessNotes ?? "",
                        usual: usual
                    )
                }
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
            if let usual { flow = .usual(usual) } else { flow = .address }
        }
    }

    /// Success needs no message: the account is gone and `Session` has already
    /// flipped to signed-out, so this view is replaced by the sign-in screen
    /// while the dialog is still dismissing.
    private func performDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await session.deleteAccount()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Gather the account's data and hand it to the share sheet.
    private func performExport() async {
        exporting = true
        defer { exporting = false }
        do {
            let url = try await store.exportAccountData()
            lastExportURL = url
            exportFile = ExportFile(url: url)
        } catch {
            exportError = "We couldn't put your data together just now. Please try again."
        }
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
        if path.last?.id != order.id { path.append(order) }
    }

    private var greeting: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(greetingText)
                    .font(.title2.weight(.semibold))
                Text("Where should we collect from?")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        return part
    }

    /// Looks like a text field, behaves like a button. Tapping opens a
    /// dedicated screen with the keyboard already up, rather than trying to
    /// type into a row inside a scrolling list.
    private var searchEntry: some View {
        Button {
            flow = .address
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("Enter your address")
                    .foregroundStyle(Theme.muted)
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Book a pickup")
        .padding(.bottom, 4)
    }
}

/// UIKit's share sheet, because `ShareLink` needs its item before the tap and
/// this one only exists after a round trip to the database.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}

private struct ApprovalBanner: View {
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

private struct ActiveOrderCard: View {
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

private struct PastOrderRow: View {
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

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bag")
                .font(.system(size: 42))
                .foregroundStyle(Theme.muted)
            Text("No orders yet")
                .font(.headline)
            Text("Schedule a pickup and we'll collect your bag, get it cleaned, and bring it back.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
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
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your usual: \(usual.summary) at \(usual.cleanerName). Book it again.")
        .accessibilityIdentifier("usual-order")
    }
}


/// The home screen's sections, split from the order list in one pass per
/// redraw instead of re-filtering it for each section (and a contains() per
/// row inside one of them).
struct OrderLists {
    let attention: [Order]
    let active: [Order]
    let activeOther: [Order]
    let past: [Order]
    let usual: UsualOrder?

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
        self.usual = UsualOrder.from(orders)
    }
}
