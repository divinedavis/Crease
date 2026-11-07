import SwiftUI

/// The soft-card look (owner, 2026-11-06): white canvas, pale grey rounded
/// cards, a 3D illustration on a grey tile for every symbol that names a
/// thing, solid grey glyphs beside the rows, a numbered stepper through the
/// booking, and one floating black bar that always shows the total.
///
/// The illustrations live in Assets › Illustrations. They are pictures of
/// things (a basket, a scooter, a receipt); controls and chevrons stay SF
/// Symbols, so nothing tappable depends on an image to be understood.
enum Illustration: String, CaseIterable {
    case basket, drycleaning, press, bedding, courier, van, laundrybag, folded
    case shop, map, house, office, receipt, washer, sunrise, sun, moon
    case padlock, lifebuoy, shield, box, scale, camera, careTag, calendar, `repeat`, welcome

    var image: Image { Image("Illustrations/\(rawValue)") }
}

extension ServiceKind {
    var illustration: Illustration {
        switch self {
        case .dryClean: .drycleaning
        case .washFold: .basket
        case .press: .press
        }
    }
}

extension ServiceOption {
    /// Round trip is the van that goes both ways; pickup only is the bag
    /// leaving; return only is the folded stack coming home.
    var illustration: Illustration {
        switch id {
        case "pickup_only": .laundrybag
        case "return_only": .folded
        default: .van
        }
    }
}

extension OrderStatus {
    /// The picture for where the bag is right now.
    var illustration: Illustration {
        switch self {
        case .scheduled, .pickupDispatched, .inTransitToCleaner, .returnDispatched, .inTransitToCustomer: .courier
        case .atCleaner: .shop
        case .awaitingApproval: .receipt
        case .cleaning: .washer
        case .ready, .delivered: .folded
        case .draft, .failed, .cancelled: .laundrybag
        }
    }
}

extension Order {
    var illustration: Illustration { status.illustration }
}

extension Order {
    /// For history rows: the folded stack for a trip that only brought
    /// clothes home, the basket otherwise (wash & fold is what's on sale).
    var serviceIllustration: Illustration {
        serviceTier == "return_only" ? .folded : .basket
    }
}

/// An illustration sitting on a soft tile — the reference's product shot.
struct IllustrationTile: View {
    let art: Illustration
    var size: CGFloat = 64
    var corner: CGFloat? = nil
    /// The tile's own fill. Cards that are already grey put a white tile on
    /// themselves, the way the reference's ETA card does.
    var fill: Color = Theme.surface
    var inset: CGFloat = 0.14

    var body: some View {
        art.image
            .resizable()
            .scaledToFit()
            .padding(size * inset)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: corner ?? size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row led by a solid grey glyph: title over a muted line, optional trailing view.
struct GlyphRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.app(size: 22).weight(.semibold))
                .foregroundStyle(Theme.glyph)
                .frame(width: 28)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.app(.body).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.app(.subheadline))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension GlyphRow where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// "① Address — ② — ③": the current step is a black dot with its name beside
/// it, finished steps are ticked, later ones are grey numbers.
struct NumberedStepper: View {
    let current: Int
    var labels: [String] = ["Address", "Order", "Checkout"]
    /// The dots grow with the numbers in them.
    @ScaledMetric(relativeTo: .subheadline) private var dot: CGFloat = 32

    var body: some View {
        HStack(spacing: 10) {
            ForEach(labels.indices, id: \.self) { i in
                let step = i + 1
                if i > 0 {
                    Capsule().fill(Theme.line).frame(width: 20, height: 2)
                        .accessibilityHidden(true)
                }
                ZStack {
                    Circle().fill(step <= current ? Theme.ink : Theme.surfaceStrong)
                    if step < current {
                        Image(systemName: "checkmark")
                            .font(.app(size: 13).weight(.bold))
                            .foregroundStyle(Theme.onInk)
                    } else {
                        Text("\(step)")
                            .font(.app(size: 15, relativeTo: .subheadline).weight(.semibold).monospacedDigit())
                            .foregroundStyle(step == current ? Theme.onInk : Theme.muted)
                    }
                }
                .frame(width: dot, height: dot)
                .accessibilityHidden(true)
                if step == current {
                    // The one part VoiceOver reads: the step's name, as a
                    // header, with where it sits in the flow as its value.
                    Text(labels[i])
                        .font(.app(.body).weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue("Step \(current) of \(labels.count)")
                }
            }
        }
    }
}

/// The floating black bar: the money on the left, the next step on the right.
/// One per screen, pinned above the home indicator.
struct TotalBar: View {
    var amount: String? = nil
    var note: String? = nil
    let action: String
    var showsArrow = true
    var busy = false
    var enabled = true
    /// Defaults to "Continue · $59.95": the action first, so VoiceOver (and
    /// the UI tests) hear what the button does before the number.
    var accessibilityText: String? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let amount {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(amount)
                            .font(.app(.title3).weight(.semibold).monospacedDigit())
                        if let note {
                            Text(note)
                                .font(.app(.caption))
                                .opacity(0.72)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                if busy {
                    ProgressView().tint(Theme.onInk)
                } else {
                    HStack(spacing: 8) {
                        Text(action).font(.app(.body).weight(.semibold))
                        if showsArrow && amount != nil {
                            Image(systemName: "arrow.right").font(.app(.body).weight(.semibold))
                        }
                    }
                }
            }
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: amount == nil ? .center : .leading)
            .frame(minHeight: 64)
            .background(Theme.ink.opacity(enabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled || busy)
        .accessibilityLabel(accessibilityText ?? (amount.map { "\(action) · \($0)" } ?? action))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// The round white "+" with a soft shadow, from the reference's product cards.
struct PlusBadge: View {
    var size: CGFloat = 36
    var symbol = "plus"

    var body: some View {
        Image(systemName: symbol)
            .font(.app(size: size * 0.42).weight(.medium))
            .foregroundStyle(Theme.glyph)
            .frame(width: size, height: size)
            .background(Theme.raised, in: Circle())
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            .accessibilityHidden(true)
    }
}

/// Round grey nav button (back, close, more).
struct CircleIconButton: View {
    let symbol: String
    let label: String
    var onMaterial = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(size: 17).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background(onMaterial ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(Theme.surface), in: Circle())
                .shadow(color: .black.opacity(onMaterial ? 0.12 : 0), radius: 8, y: 2)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Section label above a group: muted, medium weight, sentence case.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.app(.subheadline).weight(.medium))
            .foregroundStyle(Theme.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The soft grey card: 24pt continuous corners, generous padding.
    func softCard(padding: CGFloat = 18, fill: Color = Theme.surface) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// White card with a hairline, for things that sit on grey or need lift.
    func outlineCard(padding: CGFloat = 14, selected: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(selected ? Theme.ink : Theme.line, lineWidth: selected ? 2.5 : 1.5)
            )
    }
}
