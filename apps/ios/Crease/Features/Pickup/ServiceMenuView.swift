import SwiftUI

/// Choose the service, then say what is going in the bag.
///
/// Two questions in one sheet because they are one decision: dry cleaning is
/// counted in garments and laundry is weighed by the pound, so the service
/// picked decides what the customer is even being asked to enter. An order is
/// one service — the database refuses a line that is not the order's own type
/// — so switching tabs clears the count rather than quietly mixing two price
/// lists into one bag.
///
/// Every price here is the chosen shop's own. Nothing is averaged, and there
/// is no Crease price list to fall back on: if the shop has not published a
/// price for a service, that tab says so and has nothing to count. All three
/// tabs always show (owner, 2026-10-08), so a customer can switch to the
/// service they want and see plainly that this shop does not do it, rather
/// than finding the choice missing.
struct ServiceMenuView: View {
    @Environment(\.dismiss) private var dismiss

    let shopName: String
    let menu: [ServiceItem]
    @Binding var kind: ServiceKind
    @Binding var quantities: [UUID: Double]
    @ObservedObject var extras: OrderExtras

    /// Only the services this shop actually sells, in a fixed order so the tabs
    /// do not reshuffle between shops.
    private var offered: [ServiceKind] {
        ServiceKind.allCases.filter { candidate in
            menu.contains { $0.serviceType == candidate.rawValue }
        }
    }

    private var items: [ServiceItem] {
        menu.filter { $0.serviceType == kind.rawValue }
    }

    private var lines: [(item: ServiceItem, entered: Double)] {
        items.map { ($0, quantities[$0.id] ?? 0) }
    }

    private var subtotal: Int { ServicePricing.subtotalCents(lines) }

    /// A service other than the one on screen that already has something in it.
    ///
    /// An order carries one service type — the database refuses a line that is
    /// not the order's own, and a two-hour wash and a two-day dry clean cannot
    /// share a turnaround anyway. That used to be enforced by emptying the bag
    /// on every tab tap, which punished looking. Now the clash is shown, and
    /// it is one tap to resolve.
    private var conflicting: ServiceKind? {
        // A tab this shop has not priced holds nothing, so nothing clashes:
        // the booking just says the service is not offered.
        guard !items.isEmpty else { return nil }
        return offered.first { candidate in
            candidate != kind
                && menu.contains { $0.serviceType == candidate.rawValue && (quantities[$0.id] ?? 0) > 0 }
        }
    }

    /// Whether the bag can be taken as one order.
    var isResolvable: Bool { conflicting == nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // No step indicator: this sheet sits over the booking screen,
                // which already shows it (owner, 2026-11-23: "simplify").
                if !menu.isEmpty {
                    // Three equal tabs that always fit, rather than chips that
                    // scrolled "Press only" off the edge.
                    HStack(spacing: 6) {
                        ForEach(ServiceKind.allCases) { service in
                            let on = service == kind
                            Button { withAnimation(Motion.snappy) { kind = service } } label: {
                                Text(service.label)
                                    .font(.app(.subheadline).weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .foregroundStyle(on ? Theme.onInk : Theme.ink)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(on ? Theme.ink : Theme.surface, in: Capsule())
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    // Switching tabs used to empty the bag. An order does carry
                    // one service type, so that was enforcing something real —
                    // but it enforced it against somebody who only wanted to
                    // look at the laundry prices, and three counted shirts
                    // disappeared with no warning and no way back. The counts
                    // survive now, and the conflict is raised below where it
                    // can be seen and undone.
                }

                if let other = conflicting {
                    conflictBanner(other)
                }

                List {
                    if !offered.isEmpty {
                        SmartOrderTools(
                            menu: menu,
                            offered: offered,
                            kind: $kind,
                            quantities: $quantities,
                            extras: extras
                        )
                    }
                    Section {
                        if items.isEmpty && !menu.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(shopName) doesn't offer \(kind.label.lowercased()) yet")
                                    .font(.app(.subheadline).weight(.semibold))
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                        }
                        ForEach(items) { item in
                            row(item)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface)
                                )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.canvas)
                .listRowSpacing(10)
                // On a tab change only. The first fill happens when the shop's
                // price list lands, in BookPickupView — writing it from this
                // sheet's `onAppear` mutates state the presenting screen owns
                // in the middle of its own update pass, which SwiftUI resolves
                // by rebuilding both views repeatedly before it settles.
                .onChange(of: kind) { prefillMinimum() }

                // No "$0.00" for a service the shop cannot price: that reads
                // as free, not as unavailable.
                if !items.isEmpty { total }
            }
            .navigationTitle("Your order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                // The total bar carries Done; a service the shop has not
                // priced has no total bar, so it gets one up here instead.
                if items.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .disabled(!isResolvable)
                    }
                }
            }
        }
    }

    private func conflictBanner(_ other: ServiceKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("One service per order")
                    .font(.app(.footnote).weight(.semibold))
                Text("Remove \(other.label.lowercased()) to continue.")
                    .font(.app(.caption))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button("Remove") { clear(other) }
                .font(.app(.footnote).weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Theme.warnSoft)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    /// Empty one service, leaving the other exactly as it was.
    private func clear(_ service: ServiceKind) {
        for item in menu where item.serviceType == service.rawValue {
            quantities[item.id] = nil
        }
    }

    @ViewBuilder private func row(_ item: ServiceItem) -> some View {
        let entered = quantities[item.id] ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.app(.headline))
                    Text(priceLine(item))
                        .font(.app(.caption))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Text(entered > 0 ? enteredLabel(item, entered) : "—")
                    .font(.app(.title3).weight(.semibold).monospacedDigit())
                    .foregroundStyle(entered > 0 ? Theme.accent : .secondary)
                // A pound at a time above the floor, and straight to the floor
                // from nothing: the values in between all bill the same, so
                // stepping through them one tap at a time is nine taps that
                // change no price. Written with increment/decrement closures
                // rather than a range because that first step is a different
                // size from the rest, which `Stepper(value:in:step:)` cannot
                // express.
                Stepper(
                    "",
                    // nil where the range runs out, which is how a Stepper is
                    // told to grey that half out — the bounds used to come from
                    // `in:` and have to keep being visible.
                    onIncrement: entered < ceiling(item)
                        ? {
                            let next = entered <= 0 ? ServicePricing.startingUnits(item) : entered + 1
                            quantities[item.id] = min(next, ceiling(item))
                        }
                        : nil,
                    onDecrement: entered > 0
                        ? {
                            // Below the floor is not a cheaper order, it is the
                            // same order priced as the floor. So the step under
                            // it is out, and the one below that is empty.
                            let next = entered - 1
                            quantities[item.id] = next < ServicePricing.startingUnits(item) ? 0 : next
                        }
                        : nil
                )
                .labelsHidden()
            }

            if ServicePricing.minimumApplies(item, entered: entered) {
                // Said here rather than discovered at the counter: a 15 lb
                // floor turns an 8 lb bag into a 15 lb bill, and that is the
                // single most surprising number in laundry pricing.
                Text("Bills as \(unitsLabel(ServicePricing.billableUnits(item, entered: entered))) lb (minimum)")
                    .font(.app(.caption2))
                    .foregroundStyle(.orange)
            } else if item.isByWeight, entered > ServicePricing.startingUnits(item),
                      entered == LastBagSize.pounds(for: item) {
                // Why the line opened above the floor: it is the bag they
                // booked last time here, not a number the app made up.
                Text("Same as last time")
                    .font(.app(.caption2))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(priceLine(item)), \(entered > 0 ? enteredLabel(item, entered) : "none selected")")
    }

    private var total: some View {
        // The courier fee is a separate line on the screen behind this one,
        // and conflating the two is how somebody reads one number and is
        // charged the sum of both — so the bar says so under the number.
        TotalBar(
            amount: subtotal.asMoney,
            note: "Cleaning estimate",
            action: "Done",
            enabled: isResolvable,
            accessibilityText: "Estimated cleaning \(subtotal.asMoney), courier fee charged separately. Done"
        ) { dismiss() }
        // The only Done on the sheet now; found by this name, as the toolbar
        // button it replaced was.
        .accessibilityIdentifier("Done")
        .padding(.top, 8)
    }

    private func ceiling(_ item: ServiceItem) -> Double { item.isByWeight ? 200 : 99 }

    /// Open a weighed service at the shop's minimum instead of at nothing.
    ///
    /// A 10 lb floor means the bag is billed at 10 lb however light it is, so
    /// zero is not a real starting point — it is $0.00 shown for an order that
    /// cannot cost less than $20, above a stepper the customer has to tap ten
    /// times before the screen says anything true. Starting at the floor states
    /// the real opening price and leaves the tapping to people whose bag is
    /// bigger than that. What counts as openable is decided in one place, next
    /// to the pricing it is about.
    private func prefillMinimum() {
        guard let line = ServicePricing.lineToOpenAtMinimum(
            menu: menu,
            serviceType: kind.rawValue,
            entered: quantities
        ) else { return }
        quantities[line.id] = ServicePricing.openingUnits(line)
    }

    private func priceLine(_ item: ServiceItem) -> String {
        let price = item.unitPriceCents.asMoney
        guard item.isByWeight else { return "\(price) each" }
        let floor = item.minimumUnits > 0 ? " · \(unitsLabel(item.minimumUnits)) lb minimum" : ""
        return "\(price) / lb\(floor)"
    }

    private func enteredLabel(_ item: ServiceItem, _ entered: Double) -> String {
        item.isByWeight ? "\(unitsLabel(entered)) lb" : "\(Int(entered))"
    }

    /// Whole pounds read as whole pounds; the shop's scale is what produces a
    /// decimal, not this screen.
    private func unitsLabel(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
