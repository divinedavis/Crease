import SwiftUI

/// One place for the app's visual language.
///
/// The palette is intentionally quiet: this is a utility people open to answer
/// "where are my clothes", not something they browse. Colour is reserved for
/// state that matters — the one live order, the one thing needing a decision —
/// so it means something when it appears.
enum Theme {
    static let accent = Color(red: 0.12, green: 0.44, blue: 0.36)
    static let accentSoft = Color(red: 0.12, green: 0.44, blue: 0.36).opacity(0.12)
    static let warn = Color(red: 0.72, green: 0.45, blue: 0.05)
    static let warnSoft = Color(red: 0.95, green: 0.72, blue: 0.28).opacity(0.18)
    static let danger = Color(red: 0.72, green: 0.20, blue: 0.15)

    static let cardRadius: CGFloat = 16
}

extension View {
    func creaseCard() -> some View {
        self
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Status chip. Tone carries meaning, but never alone — the label always says
/// the same thing the colour does, so it survives colour-blindness and
/// grayscale accessibility modes.
struct StatusPill: View {
    let status: OrderStatus

    private var tone: (fg: Color, bg: Color) {
        switch status {
        case .awaitingApproval, .failed: (Theme.warn, Theme.warnSoft)
        case .cancelled: (.secondary, Color(.tertiarySystemFill))
        case .delivered: (.secondary, Color(.tertiarySystemFill))
        default: (Theme.accent, Theme.accentSoft)
        }
    }

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tone.fg)
            .background(tone.bg, in: Capsule())
    }
}

/// Four-stop progress track for the two-leg journey.
///
/// Deliberately shows the whole arc, including the days at the cleaner, so the
/// two-day gap in the middle reads as an expected part of the process rather
/// than as the app having gone quiet.
struct JourneyTrack: View {
    let status: OrderStatus

    private let steps = ["Pickup", "At cleaner", "Cleaning", "Return"]

    var body: some View {
        let current = status.stepIndex ?? -1

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i < max(current, 0) || (i == current && current >= 0)
                              ? Theme.accent : Color(.quaternaryLabel))
                        .frame(height: 5)
                }
            }
            HStack {
                ForEach(steps.indices, id: \.self) { i in
                    Text(steps[i])
                        .font(.caption2)
                        .foregroundStyle(i <= current ? Theme.accent : .secondary)
                        .frame(maxWidth: .infinity, alignment: i == 0 ? .leading
                               : (i == steps.count - 1 ? .trailing : .center))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress: \(status.title)")
    }
}
