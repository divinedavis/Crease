import SwiftUI
import UIKit
import CoreText

/// One place for the app's visual language.
///
/// The palette is intentionally quiet: this is a utility people open to answer
/// "where are my clothes", not something they browse. Colour is reserved for
/// state that matters — the one live order, the one thing needing a decision —
/// so it means something when it appears.
enum Theme {
    // Espresso since 2026-11-23 (owner's pick of ten palettes drawn from the
    // Pleat logo): a near-black brown carries text and every primary action,
    // cards are a warm grey, and the logo's terracotta is the one accent —
    // the selected tab, the map route, status lines. Before this the app was
    // monochrome (ink = black/white, 2026-10-08).
    //
    // Dark mode mirrors it: cream ink on the splash's near-black, with a
    // lighter terracotta so accent text stays above 4.5:1 on the cards.
    // SplashBackground's dark value is the dark canvas, so the launch hands
    // off without a seam.
    static let ink = hex(light: 0x2B1D18, dark: 0xFFF6EE)
    /// Text and icons drawn ON an ink fill.
    static let onInk = hex(light: 0xFFF6EE, dark: 0x1A1412)
    /// The logo's terracotta, a shade deeper in light mode so text in it
    /// passes 4.5:1 on `surface` (the logo's #B8573A reads 4.2:1 there).
    static let accent = hex(light: 0xA84E32, dark: 0xE0805F)
    static let accentSoft = ink.opacity(0.08)
    /// For FILLS under `onInk` text (primary buttons, capsules).
    static let accentFill = ink
    /// The page: white in light mode, the splash's near-black in dark.
    static let canvas = hex(light: 0xFFFFFF, dark: 0x1A1412)
    /// Cards, search pills and tiles sitting on the canvas: a warm grey that
    /// sits with the illustrations and the brown ink.
    static let surface = hex(light: 0xF4F1EE, dark: 0x261E1B)
    /// Raised a step above `surface` (rows inside a card, chips).
    static let surfaceRaised = Color(.tertiarySystemBackground)
    /// One shade darker than `surface`: inactive stepper dots, tracks.
    static let surfaceStrong = hex(light: 0xECE7E2, dark: 0x342A26)
    /// White in light mode: the "+" badges and tiles placed on a grey card.
    static let raised = hex(light: 0xFFFFFF, dark: 0x2F2622)
    /// Hairlines and unselected outlines.
    static let line = hex(light: 0xE8E2DC, dark: 0x3A302B)
    /// The solid colour of the row glyphs (pin, clock, note).
    static let glyph = hex(light: 0x6B4A3C, dark: 0xC9B2A6)
    /// Secondary text. The system's .secondary / .tertiary read "nearly
    /// passed" / "failed" in Apple's contrast audit on these backgrounds;
    /// this is ~6.5:1 on cards in both modes.
    static let muted = hex(light: 0x5E524C, dark: 0xBFB3AC)
    static let warn = adaptive(light: (0.50, 0.29, 0.0), dark: (0.95, 0.68, 0.25))
    static let warnSoft = Color(red: 0.95, green: 0.72, blue: 0.28).opacity(0.18)
    static let danger = adaptive(light: (0.62, 0.15, 0.12), dark: (1.0, 0.45, 0.40))

    /// A light/dark pair from hex values.
    static func hex(light: UInt32, dark: UInt32) -> Color {
        func ui(_ h: UInt32) -> UIColor {
            UIColor(red: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
                    blue: CGFloat(h & 0xff) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let cardRadius: CGFloat = 24
}

extension View {
    func creaseCard() -> some View {
        self
            .padding(18)
            .background(Theme.surface)
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
            .font(.app(.caption).weight(.semibold))
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
                                .font(.app(size: 8).weight(.bold))
                        }
                        Text(steps[i])
                            .font(.app(.caption2).weight(.semibold))
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

// MARK: - Type (Plus Jakarta Sans, owner's pick 2026-11-06)

/// The app's one typeface. Five static weights ship in Resources/Fonts
/// (Regular, Medium, SemiBold, Bold, ExtraBold — SIL OFL, licence beside them)
/// and are registered through UIAppFonts. `.weight()` on these fonts resolves
/// to the matching face within the family.
enum AppFont {
    static let regular = "PlusJakartaSans-Regular"
    static let family = "Plus Jakarta Sans"

    /// Apple's default point sizes, so every text style keeps the size it had
    /// under SF Pro and still scales with Dynamic Type.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }

    /// UIKit's copy, for the navigation and tab bars SwiftUI draws through UIKit.
    static func ui(_ size: CGFloat, weight: UIFont.Weight, relativeTo style: UIFont.TextStyle) -> UIFont {
        let name: String = switch weight {
        case .medium: "PlusJakartaSans-Medium"
        case .semibold: "PlusJakartaSans-SemiBold"
        case .bold: "PlusJakartaSans-Bold"
        case .heavy, .black: "PlusJakartaSans-ExtraBold"
        default: regular
        }
        let font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    /// Bars are UIKit underneath SwiftUI: their titles and tab labels only
    /// change through appearance proxies.
    static func applyToBars() {
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: ui(17, weight: .regular, relativeTo: .body)]
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.buttonAppearance = button
        nav.titleTextAttributes = [.font: ui(17, weight: .semibold, relativeTo: .headline)]
        nav.largeTitleTextAttributes = [.font: ui(34, weight: .bold, relativeTo: .largeTitle)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.titleTextAttributes = nav.titleTextAttributes
        edge.largeTitleTextAttributes = nav.largeTitleTextAttributes
        edge.buttonAppearance = button
        UINavigationBar.appearance().scrollEdgeAppearance = edge
        UITabBarItem.appearance().setTitleTextAttributes(
            [.font: ui(10, weight: .semibold, relativeTo: .caption2)], for: .normal)
    }
}

// MARK: - Wordmark (Playfair Display Italic, owner's pick 2026-11-23)

/// The "crease" wordmark's face, which matches the Pleat app icon. Only the
/// wordmark uses it; everything else stays in Plus Jakarta Sans.
///
/// The font ships as the unmodified variable file (its licence reserves the
/// name, so no static Bold cut can be made from it), and `.weight()` does not
/// reach a variable font's axis reliably, so the weight is set on the `wght`
/// axis directly.
enum WordmarkFont {
    static let postScriptName = "PlayfairDisplay-Italic"
    static let weight: CGFloat = 700
    /// The OpenType tag 'wght' as a number, the key Core Text expects.
    static let weightAxis = 0x7767_6874

    static func uiFont(size: CGFloat) -> UIFont {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: postScriptName,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                [NSNumber(value: weightAxis): NSNumber(value: Double(weight))],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// "crease" in the wordmark face. Scales with Dynamic Type relative to a text
/// style unless `relativeTo` is nil (the splash, which matches the launch).
struct WordmarkText: View {
    @ScaledMetric private var scaledSize: CGFloat
    private let baseSize: CGFloat
    private let scales: Bool

    init(size: CGFloat, relativeTo style: Font.TextStyle? = nil) {
        baseSize = size
        scales = style != nil
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: style ?? .body)
    }

    var body: some View {
        Text("crease")
            .font(Font(WordmarkFont.uiFont(size: scales ? scaledSize : baseSize)))
            .accessibilityLabel("Crease")
    }
}

extension Font {
    /// A text style in the app's typeface, scaling with Dynamic Type.
    /// `.headline` keeps its semibold, as the system's does.
    static func app(_ style: Font.TextStyle) -> Font {
        let font = Font.custom(AppFont.regular, size: AppFont.size(style), relativeTo: style)
        return style == .headline ? font.weight(.semibold) : font
    }

    /// A fixed size in the app's typeface, for the places that used
    /// `.system(size:)` and deliberately do not scale (icons, wordmarks).
    static func app(size: CGFloat) -> Font {
        .custom(AppFont.regular, fixedSize: size)
    }

    /// A chosen size that still scales with Dynamic Type, relative to a text
    /// style: wordmarks, the stepper's numbers, hero figures. Apple's audit
    /// fails text that cannot grow.
    static func app(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(AppFont.regular, size: size, relativeTo: style)
    }
}
