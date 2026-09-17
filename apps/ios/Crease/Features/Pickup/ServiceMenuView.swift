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
/// price for a service, the service is not offered.
struct ServiceMenuView: View {
    @Environment(\.dismiss) private var dismiss

    let shopName: String
    let menu: [ServiceItem]
    @Binding var kind: ServiceKind
    @Binding var quantities: [UUID: Double]

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
        offered.first { candidate in
            candidate != kind
                && menu.contains { $0.serviceType == candidate.rawValue && (quantities[$0.id] ?? 0) > 0 }
        }
    }

    /// Whether the bag can be taken as one order.
    var isResolvable: Bool { conflicting == nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if offered.count > 1 {
                    Picker("Service", selection: $kind) {
                        ForEach(offered) { service in
                            Text(service.label).tag(service)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
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
                    Section {
                        ForEach(items) { item in
                            row(item)
                        }
                    } header: {
                        Text(kind.prompt)
                    } footer: {
                        Text("These are \(shopName)'s prices. They count the bag at the counter and that count is what you pay — this is what to expect.")
                    }
                }
                .listStyle(.insetGrouped)
                // On a tab change only. The first fill happens when the shop's
                // price list lands, in BookPickupView — writing it from this
                // sheet's `onAppear` mutates state the presenting screen owns
                // in the middle of its own update pass, which SwiftUI resolves
                // by rebuilding both views repeatedly before it settles.
                .onChange(of: kind) { prefillMinimum() }

                total
            }
            .navigationTitle("Your order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(!isResolvable)
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
                    .font(.footnote.weight(.semibold))
                Text("You've also got \(other.label.lowercased()) in this bag. They're cleaned on different machines and come back on different days, so they have to be booked separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Remove") { clear(other) }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.subheadline.weight(.medium))
                    Text(priceLine(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(entered > 0 ? enteredLabel(item, entered) : "—")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
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
                Text("\(shopName) has a \(unitsLabel(item.minimumUnits)) lb minimum, so this bills as \(unitsLabel(ServicePricing.billableUnits(item, entered: entered))) lb.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if entered == ServicePricing.startingUnits(item), item.minimumUnits > 0 {
                // Why the line already has a number in it. A count nobody
                // typed needs saying, or it reads as the app having decided how
                // much laundry they have — and the floor is the one weight it
                // can state without guessing.
                Text("That's \(shopName)'s minimum, so it's where this starts. Add pounds if your bag is bigger.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(priceLine(item)), \(entered > 0 ? enteredLabel(item, entered) : "none selected")")
    }

    private var total: some View {
        VStack(spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Estimated cleaning")
                        .font(.subheadline.weight(.medium))
                    // The courier fee is a separate line on the screen behind
                    // this one, and conflating the two is how somebody reads
                    // one number and is charged the sum of both.
                    Text("Courier fee is charged separately")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(subtotal.asMoney)
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated cleaning \(subtotal.asMoney), courier fee charged separately")
    }

    /// The most this line will take. Two hundred pounds is a laundromat run,
    /// ninety-nine garments is a wardrobe; past either, the number is a typo.
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
        quantities[line.id] = line.minimumUnits
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
