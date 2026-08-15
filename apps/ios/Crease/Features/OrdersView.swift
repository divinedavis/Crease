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

        var id: String {
            switch self {
            case .address: "address"
            case .pin: "pin"
            case .book: "book"
            }
        }
    }

    private var active: [Order] { store.orders.filter { $0.status.isActive } }
    private var past: [Order] { store.orders.filter { !$0.status.isActive } }
    /// Anything waiting on the customer: an intake above their hold, or clean
    /// clothes with no delivery time chosen.
    private var needsAttention: [Order] {
        store.orders.filter { $0.status == .awaitingApproval || $0.needsReturnScheduling }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    greeting
                    searchEntry

                    ForEach(needsAttention) { order in
                        NavigationLink(value: order) {
                            ApprovalBanner(order: order)
                        }
                        .buttonStyle(.plain)
                    }

                    if active.isEmpty && store.orders.isEmpty && !store.isLoading {
                        EmptyState()
                            .padding(.top, 40)
                    }

                    ForEach(active.filter { !needsAttention.contains($0) }) { order in
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
            .sheet(item: $exportFile) { file in
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
                }
            }
        }
        .task {
            await store.loadAll()
            await store.startWatching()
        }
        .task(id: router.pendingOrderId) { await openTappedOrder() }
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
            exportFile = ExportFile(url: try await store.exportAccountData())
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            JourneyTrack(order: order)

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
                // No number until the shop has one. "$0.00 est." is not a
                // cheap order, it is the absence of a price rendered as money.
                if let price = order.priceText {
                    Text(price)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    if order.isEstimate {
                        Text("est.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Priced after counting")
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
            // A cancelled order never reached a counter, so it has no price and
            // an em dash is the honest column.
            Text(order.priceText ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .creaseCard()
    }
}

private struct EmptyState: View {
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
