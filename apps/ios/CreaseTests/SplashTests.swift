import Testing
import UIKit
@testable import Crease

/// The Pleat "Draw" splash (owner, 2026-11-23). The launch screen and the
/// splash must share one colour or the hand-off flashes, and the drawing must
/// finish before the splash is allowed to lift.
struct SplashTests {
    @Test func theLaunchScreenUsesTheSplashColour() throws {
        let launch = try #require(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])
        #expect(launch["UIColorName"] as? String == "SplashBackground")
        #expect(UIColor(named: "SplashBackground") != nil)
    }

    @Test func theSplashIsCreamInLightAndNearBlackInDark() throws {
        let colour = try #require(UIColor(named: "SplashBackground"))
        let light = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        light.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r > 0.95 && g > 0.9 && b > 0.88)
        dark.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r < 0.15 && g < 0.15 && b < 0.15)
    }

    @Test func thePleatMatchesTheIcon() {
        // The icon's zigzag: three folds, alternating 62 and 38 on its canvas.
        #expect(PleatStroke.points.count == 6)
        #expect(PleatStroke.points.map(\.y) == [62, 38, 62, 38, 62, 38])
        let path = PleatStroke().path(in: CGRect(x: 0, y: 0, width: 150, height: 150))
        #expect(abs(path.boundingRect.minX - 27) < 0.01)
        #expect(abs(path.boundingRect.maxX - 117) < 0.01)
    }

    @Test func theDrawingFinishesBeforeTheSplashCanLift() {
        // Word rises from 1.0 s for 0.45 s; the lift may start at 1.8 s.
        #expect(SplashView.introLength >= 1.45)
        #expect(SplashView.introLength <= 2.0)
    }
}
