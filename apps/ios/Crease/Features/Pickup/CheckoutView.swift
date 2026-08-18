import SwiftUI

/// The receipt before the charge.
///
/// Crease is merchant of record on the whole order — one card charge covers
/// the cleaning and the couriers, and the shop is paid out of it afterwards by
/// whichever rail they signed up for. That is one payment for the customer,
/// which is the right experience, but it also means the app must show what the
/// money is buying before it takes any. The booking screen showed a courier
/// fee alone and called the cleaning "billed separately by the shop", which
/// was never what the code did.
///
/// It is a screen of its own rather than a card on the map for a mechanical
/// reason: Stripe's sheet grows from the bottom by an amount only Stripe
/// decides — every wallet row it offers makes it taller — so anything low on
/// the screen gets covered exactly when it needs to be read. Here the money
/// sits at the top, where nothing can reach it.
struct CheckoutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Anything that went wrong while paying. Rendered here rather than on the
    /// booking screen underneath: a full-screen cover hides its parent, so an
    /// error written there is an error nobody reads — a tap that looks like it
    /// did nothing at all.
    let errorMessage: String?
    /// False for a return: the clothes are at the shop already and already paid
    /// for, so there is no cleaning line, no itemisation and nothing for the
    /// counter to price. All this order buys is the trip home.
    let carriesCleaning: Bool
    let shopName: String
    let serviceLabel: String
    let lines: [(item: ServiceItem, entered: Double)]
    let cleaningCents: Int
    let deliveryLabel: String
    let deliveryFeeCents: Int
    let serviceFeeCents: Int
    let taxCents: Int
    /// What the card is authorized for, which is more than the total: the shop
    /// has not opened the bag yet, and a hold with no headroom means any extra
    /// sock stops the order to ask. Shown because Stripe's own sheet will
    /// display this number, and a customer meeting it for the first time on
    /// the Pay button reads it as being overcharged.
    let holdCents: Int
    let working: Bool
    let onPay: () -> Void

    private var totalCents: Int { cleaningCents + deliveryFeeCents + serviceFeeCents + taxCents }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    shopCard
                    if carriesCleaning { itemCard }
                    totals
                    holdNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                        .disabled(working)
                }
            }
            .safeAreaInset(edge: .bottom) { payBar }
        }
        .interactiveDismissDisabled(working)
    }

    private var shopCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.fill")
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(shopName).font(.headline)
                Text(itemSummary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Every garment on its own line, priced. The shop re-counts the bag and
    /// that count is what settles — but a customer disputing a total needs to
    /// be able to see which line they disagree with.
    private var itemCard: some View {
        VStack(spacing: 10) {
            ForEach(lines, id: \.item.id) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(quantityLabel(line))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 46, alignment: .leading)
                    Text(line.item.label).font(.subheadline)
                    Spacer(minLength: 8)
                    Text(ServicePricing.lineTotalCents(line.item, entered: line.entered).asMoney)
                        .font(.subheadline.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var totals: some View {
        VStack(spacing: 10) {
            if carriesCleaning { totalRow(serviceLabel, cleaningCents) }
            totalRow(deliveryLabel, deliveryFeeCents)
            if serviceFeeCents > 0 { totalRow("Service fee", serviceFeeCents) }
            if taxCents > 0 { totalRow("Taxes", taxCents) }
            Divider()
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text(totalCents.asMoney).font(.headline.monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Total \(totalCents.asMoney)")
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func totalRow(_ label: String, _ cents: Int) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(cents.asMoney).font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(cents.asMoney)")
    }

    private var holdNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(holdCents.asMoney) is held, not charged", systemImage: "lock.shield")
                .font(.footnote.weight(.medium))
            Text(holdExplainer)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Said before the card is taken, not discovered at cancellation.
            // A fee somebody meets for the first time on their statement is a
            // chargeback, however fair it was.
            Text("Cancel before a driver is assigned and you pay nothing. After that, the trip we've already paid for is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var payBar: some View {
        Button(action: onPay) {
            Group {
                if working {
                    ProgressView().tint(.white)
                } else {
                    Text(payLabel)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.large)
        .disabled(working)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    private var payLabel: String { "Pay \(totalCents.asMoney)" }

    private var holdExplainer: String {
        carriesCleaning
            ? "We hold exactly what this comes to — never more. \(shopName) counts the bag, and if it matches what you picked you pay \(totalCents.asMoney) and nothing else. If they count more, we ask you before taking another penny."
            : "You've already settled the cleaning with \(shopName), so this is the trip home and nothing else. We ask them to confirm your order is there and finished, and you pick a delivery time once they do."
    }

    private var itemSummary: String {
        guard carriesCleaning else { return "Bringing your finished order home" }
        guard !lines.isEmpty else { return serviceLabel }
        let pieces = lines.filter { !$0.item.isByWeight }.reduce(0.0) { $0 + $1.entered }
        let pounds = lines.filter(\.item.isByWeight).reduce(0.0) { $0 + $1.entered }
        var parts: [String] = []
        if pieces > 0 { parts.append("\(Int(pieces)) item\(pieces == 1 ? "" : "s")") }
        if pounds > 0 { parts.append("\(number(pounds)) lb") }
        return "\(serviceLabel) · \(parts.joined(separator: ", "))"
    }

    private func quantityLabel(_ line: (item: ServiceItem, entered: Double)) -> String {
        line.item.isByWeight ? "\(number(line.entered)) lb" : "\(Int(line.entered)) ×"
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
