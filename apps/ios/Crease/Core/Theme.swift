import SwiftUI
import UIKit

/// One place for the app's visual language.
///
/// The palette is intentionally quiet: this is a utility people open to answer
/// "where are my clothes", not something they browse. Colour is reserved for
/// state that matters — the one live order, the one thing needing a decision —
/// so it means something when it appears.
enum Theme {
    // Each colour has a dark-mode twin (2026-10-03): the light values read
    // under 3:1 on a dark background, which Apple's accessibility audit
    // failed on every order screen. Light values are unchanged except warn,
    // which was 3.8:1 on white and under 4.5:1 on its own amber card (was 0.72/0.45/0.05). The dark accent keeps
    // white button text above 3:1 (large/bold text) while reading 4.7:1 as text.
    static let accent = adaptive(light: (0.12, 0.44, 0.36), dark: (0.27, 0.58, 0.47))
    static let accentSoft = accent.opacity(0.12)
    /// For FILLS under white text (prominent buttons, capsules): the light
    /// green in both modes, so the white label stays 5.9:1 in dark mode too.
    static let accentFill = Color(red: 0.12, green: 0.44, blue: 0.36)
    /// Secondary text. The system's .secondary / .tertiary read "nearly
    /// passed" / "failed" in Apple's contrast audit on these backgrounds;
    /// this is ~7:1 in both modes.
    static let muted = adaptive(light: (0.33, 0.33, 0.36), dark: (0.70, 0.70, 0.74))
    static let warn = adaptive(light: (0.50, 0.29, 0.0), dark: (0.95, 0.68, 0.25))
    static let warnSoft = Color(red: 0.95, green: 0.72, blue: 0.28).opacity(0.18)
    static let danger = adaptive(light: (0.62, 0.15, 0.12), dark: (1.0, 0.45, 0.40))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

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
    /// Supplied by the order rather than fixed here: the track used to promise
    /// a "Return" leg on every order, including the tier that never bought one.
    let steps: [String]

    init(order: Order) {
        status = order.status
        steps = order.journeySteps
    }

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
                    // A lit segment says "we got at least this far", which is
                    // not the same as "this step is done" — the step someone
                    // is standing in is lit too. The tick separates them, so a
                    // pickup that actually happened reads as an event rather
                    // than as a colour.
                    HStack(spacing: 3) {
                        if i < current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text(steps[i])
                            .font(.caption2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)   // wraps at large text sizes
                    }
                    .foregroundStyle(i <= current ? Theme.accent : Color(.label).opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading
                           : (i == steps.count - 1 ? .trailing : .center))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(current: current))
    }

    /// VoiceOver gets the ticks too: without them the track reads as a status
    /// it already heard from the card above it.
    private func accessibilityText(current: Int) -> String {
        let done = steps.prefix(max(current, 0))
        let progress = "Progress: \(status.title)"
        guard !done.isEmpty else { return progress }
        return "\(progress). Completed: \(done.joined(separator: ", "))"
    }
}
