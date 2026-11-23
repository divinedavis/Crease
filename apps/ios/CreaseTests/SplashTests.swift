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
        // Word rises from 1.35 s for 0.45 s; the flight may start at 1.95 s.
        #expect(SplashView.introLength >= 1.8)
        #expect(SplashView.introLength <= 2.0)
    }

    @Test func theWordFliesOntoTheHeaderWordmark() throws {
        // The splash word at rest mid-screen, and the Home bar's wordmark
        // where it has settled under the cream.
        let word = CGRect(x: 137, y: 407, width: 128, height: 61)
        let header = CGRect(x: 161, y: 78, width: 78, height: 37)
        let flight = try #require(SplashView.flight(from: word, to: header))
        #expect(abs(flight.offset.width - (200 - 201)) < 0.001)
        #expect(abs(flight.offset.height - (96.5 - 437.5)) < 0.001)
        #expect(abs(flight.scale - 78.0 / 128.0) < 0.0001)
        // The cream shrinks to a strip just below where the word lands.
        #expect(abs(flight.stripBottom - (78 + 37 + 14)) < 0.001)
    }

    @Test func noFlightBeforeEitherWordIsMeasured() {
        #expect(SplashView.flight(from: .zero, to: CGRect(x: 0, y: 0, width: 78, height: 37)) == nil)
        #expect(SplashView.flight(from: CGRect(x: 0, y: 0, width: 128, height: 61), to: .zero) == nil)
    }
}

