import SwiftUI
import Testing
import UIKit
@testable import Crease

/// The Espresso palette (owner, 2026-11-23). Apple's accessibility audit only
/// looks at the screens the UI tests reach; this checks every text-on-surface
/// pair the palette is built from, in both modes, against WCAG's ratios.
struct ThemeContrastTests {
    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        let c = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private func ratio(_ a: Color, _ b: Color, _ style: UIUserInterfaceStyle) -> Double {
        let (x, y) = (luminance(a, style), luminance(b, style))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func bodyTextIsHighContrastOnEveryBackground(_ style: UIUserInterfaceStyle) {
        for bg in [Theme.canvas, Theme.surface, Theme.raised] {
            #expect(ratio(Theme.ink, bg, style) >= 7)
            #expect(ratio(Theme.muted, bg, style) >= 4.5)
        }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func terracottaTextPassesOnPageAndCards(_ style: UIUserInterfaceStyle) {
        for bg in [Theme.canvas, Theme.surface, Theme.raised] {
            #expect(ratio(Theme.accent, bg, style) >= 4.5)
        }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func buttonLabelsReadOnTheEspressoFill(_ style: UIUserInterfaceStyle) {
        #expect(ratio(Theme.onInk, Theme.accentFill, style) >= 7)
    }

    @Test func darkModeSharesTheSplashCanvas() throws {
        let splash = try #require(UIColor(named: "SplashBackground"))
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let canvas = UIColor(Theme.canvas).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        func rgb(_ c: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }
        for (x, y) in zip(rgb(splash), rgb(canvas)) { #expect(abs(x - y) < 0.003) }
    }
}
