import SwiftUI
import UIKit

/// Launch splash: the Pleat mark draws itself, becomes the word, and the
/// word becomes the header (owner's picks, 2026-11-23: "Draw" of five
/// splash animations, then "Becomes the bar" of ten logo-to-header ones).
///
/// On the brand's cream the pleat is drawn in one stroke and its pressed line
/// slides out under it. The mark then steps up and away and "crease" rises
/// into its place. When the app knows where it is going, the whole cream
/// screen shrinks up into a strip at the top, carrying the word with it, and
/// the word lands exactly on the screen's own wordmark (the Home bar, or the
/// sign-in title) before the strip melts into the page. Where that wordmark
/// is comes from `SplashTarget`, which the real one reports; with no target
/// the splash simply lifts away.
///
/// The exit is the "we're ready" signal, not a timer: `ready` is the auth
/// gate having resolved. The intro always finishes first, so a fast launch
/// never cuts the drawing off; a slow keychain read keeps the word up rather
/// than lifting it to reveal a spinner.
///
/// The cream matches the launch screen (the `SplashBackground` colour, which
/// Info.plist's UILaunchScreen also names), so the hand-off from the static
/// launch image is invisible. Reduce Motion gets the finished word and a
/// plain crossfade.
struct SplashView: View {
    /// True once the screen behind this one is the real one.
    let ready: Bool
    /// Fired as soon as `ready`: the screen underneath fades and rises into
    /// place while the opaque cream still hides it, so its wordmark has
    /// settled by the time the splash word flies onto it. (Measured on
    /// launch: the Home bar's wordmark moves 26 pt as it settles.)
    let onPrepare: () -> Void
    /// Fired as the overlay starts lifting: the screen underneath takes
    /// touches and VoiceOver from here.
    let onReveal: () -> Void
    /// Fired once, after the last frame, so the owner can drop the overlay.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Timings from the approved mock-ups (seconds from first frame).
    private static let drawStart: TimeInterval = 0.15
    private static let drawLength: TimeInterval = 0.75
    private static let pressStart: TimeInterval = 0.8
    private static let pressLength: TimeInterval = 0.35
    private static let markOutStart: TimeInterval = 1.25
    private static let markOutLength: TimeInterval = 0.35
    private static let wordStart: TimeInterval = 1.35
    private static let wordLength: TimeInterval = 0.45
    /// The word stays up a beat before it can move.
    static let introLength: TimeInterval = 1.95
    /// Reduce Motion skips the drawing, so only a short hold.
    private static let stillHold: TimeInterval = 0.7
    /// The flight up into the header, with the cream shrinking behind it.
    static let flightLength: TimeInterval = 0.75
    /// Then the cream strip melts away and the real wordmark takes over.
    private static let meltLength: TimeInterval = 0.35
    private static let liftLength: TimeInterval = 0.45
    /// How long the screen underneath gets to settle after `onPrepare`
    /// (its rise is 0.4 s) before the word flies to where it is.
    static let settleTime: TimeInterval = 0.5
    /// How long to wait, beyond that, for the screen to say where its
    /// wordmark is before lifting away without it.
    private static let targetWait: TimeInterval = 0.6

    /// The pleat's brand colour (the app icon's terracotta), on cream and on
    /// the dark launch colour alike.
    static let markColor = Color(red: 0.722, green: 0.341, blue: 0.227)
    /// Deep brown on cream; cream on the dark launch colour.
    static let wordColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.965, blue: 0.933, alpha: 1)
            : UIColor(red: 0.494, green: 0.212, blue: 0.133, alpha: 1)
    })

    @State private var heldLongEnough = false
    /// `ready` as last seen. The `.task` closure below captures the view value
    /// it was created with, so reading `ready` from inside it after the hold
    /// gives the value at launch, false, and the exit never plays. State is
    /// read through storage, so it is current.
    @State private var isReady = false
    @State private var preparedAt: Date?
    @State private var exiting = false
    @State private var drawn: CGFloat = 0
    @State private var pressed: CGFloat = 0
    @State private var markShown = true
    @State private var wordShown = false
    /// Where the word sits at rest, measured, so the flight knows its start.
    @State private var wordFrame: CGRect = .zero
    @State private var flightOffset: CGSize = .zero
    @State private var flightScale: CGFloat = 1
    @State private var landed = false
    @State private var wordOpacity = 1.0
    /// Nil while the cream fills the screen; the strip's height once it
    /// shrinks up behind the header.
    @State private var stripBottom: CGFloat?
    @State private var lifted = false
    @State private var coverOpacity = 1.0
    @State private var overallOpacity = 1.0

    var body: some View {
        ZStack {
            // A reader that itself ignores the safe area reports the whole
            // screen, which is what the strip shrinks from.
            GeometryReader { g in
                Color("SplashBackground")
                    .frame(height: stripBottom ?? g.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea()
            .opacity(coverOpacity)

            ZStack {
                ZStack {
                    PleatStroke()
                        .trim(from: 0, to: drawn)
                        .stroke(Self.markColor, style: StrokeStyle(lineWidth: 150 * 0.075, lineCap: .round, lineJoin: .round))
                    PressLine()
                        .stroke(Self.markColor, style: StrokeStyle(lineWidth: 150 * 0.03, lineCap: .round))
                        .scaleEffect(x: pressed, y: 1, anchor: .center)
                        .opacity(0.55)
                }
                .frame(width: 150, height: 150)
                .opacity(markShown ? 1 : 0)
                .offset(y: markShown ? 0 : -14)

                Text("crease")
                    .font(Font(WordmarkFont.uiFont(size: 46)))
                    .foregroundStyle(landed ? Theme.ink : Self.wordColor)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { wordFrame = $0 }
                    .opacity(wordShown ? wordOpacity : 0)
                    .offset(y: wordShown ? 0 : 12)
                    .scaleEffect(flightScale)
                    .offset(flightOffset)
            }
            .offset(y: lifted ? -40 : 0)
            .scaleEffect(lifted ? 1.15 : 1)
            .opacity(lifted ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Crease")
            .accessibilityIdentifier("splash.wordmark")
        }
        .ignoresSafeArea()
        .opacity(overallOpacity)
        // Once lifting, taps fall through to the screen rising underneath
        // instead of landing on a fading cover.
        .allowsHitTesting(!exiting)
        .task {
            playIntro()
            try? await Task.sleep(for: .seconds(reduceMotion ? Self.stillHold : Self.introLength))
            heldLongEnough = true
            exitIfDue()
        }
        .onAppear {
            isReady = ready
            exitIfDue()
        }
        .onChange(of: ready) { _, now in
            isReady = now
            exitIfDue()
        }
    }

    private func playIntro() {
        if reduceMotion {
            drawn = 1; pressed = 1; markShown = false; wordShown = true
            return
        }
        withAnimation(.timingCurve(0.6, 0, 0.2, 1, duration: Self.drawLength).delay(Self.drawStart)) { drawn = 1 }
        withAnimation(.easeOut(duration: Self.pressLength).delay(Self.pressStart)) { pressed = 1 }
        withAnimation(.easeIn(duration: Self.markOutLength).delay(Self.markOutStart)) { markShown = false }
        withAnimation(.easeOut(duration: Self.wordLength).delay(Self.wordStart)) { wordShown = true }
    }

    private func exitIfDue() {
        if isReady, preparedAt == nil {
            preparedAt = .now
            onPrepare()
        }
        guard isReady, heldLongEnough, !exiting else { return }
        exiting = true
        if reduceMotion {
            onReveal()
            // A plain crossfade: nothing moves.
            withAnimation(.easeOut(duration: Self.liftLength)) { overallOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftLength, execute: onFinished)
            return
        }
        Task { @MainActor in
            // Let the screen underneath finish rising into place, then wait
            // for it to report its wordmark if it has not yet.
            let settling = Self.settleTime - Date.now.timeIntervalSince(preparedAt ?? .now)
            if settling > 0 { try? await Task.sleep(for: .seconds(settling)) }
            var waited: TimeInterval = 0
            while SplashTarget.shared.frame == nil, waited < Self.targetWait {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 0.05
            }
            if let target = SplashTarget.shared.frame, let flight = Self.flight(from: wordFrame, to: target) {
                fly(flight)
            } else {
                liftAway()
            }
        }
    }

    /// Where the word goes: its centre onto the target's, scaled to its
    /// width. The target has already settled (see `onPrepare`).
    static func flight(from word: CGRect, to target: CGRect) -> (offset: CGSize, scale: CGFloat, stripBottom: CGFloat)? {
        guard word.width > 0, target.width > 0 else { return nil }
        return (
            CGSize(width: target.midX - word.midX, height: target.midY - word.midY),
            target.width / word.width,
            target.maxY + 14
        )
    }

    private func fly(_ flight: (offset: CGSize, scale: CGFloat, stripBottom: CGFloat)) {
        onReveal()
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: Self.flightLength)) {
            flightOffset = flight.offset
            flightScale = flight.scale
            stripBottom = flight.stripBottom
            landed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flightLength) {
            withAnimation(.easeIn(duration: Self.meltLength)) { coverOpacity = 0 }
            withAnimation(.linear(duration: 0.25).delay(Self.meltLength * 0.6)) { wordOpacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flightLength + Self.meltLength + 0.1, execute: onFinished)
    }

    private func liftAway() {
        onReveal()
        withAnimation(.easeIn(duration: Self.liftLength)) {
            coverOpacity = 0
            lifted = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftLength, execute: onFinished)
    }
}

/// Where the screen's own "crease" wordmark is, so the splash word can land
/// on it. The Home bar and the sign-in title report themselves; whichever is
/// on screen when the splash exits is the target.
@MainActor @Observable
final class SplashTarget {
    static let shared = SplashTarget()
    var frame: CGRect?
}

/// The Pleat mark's zigzag, on the icon's 100-point canvas.
struct PleatStroke: Shape {
    static let points: [CGPoint] = [
        CGPoint(x: 18, y: 62), CGPoint(x: 30, y: 38), CGPoint(x: 42, y: 62),
        CGPoint(x: 54, y: 38), CGPoint(x: 66, y: 62), CGPoint(x: 78, y: 38),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (i, p) in Self.points.enumerated() {
            let point = CGPoint(x: rect.minX + p.x / 100 * rect.width, y: rect.minY + p.y / 100 * rect.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The pressed line under the pleat.
struct PressLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 0.2 * rect.width, y: rect.minY + 0.74 * rect.height))
        path.addLine(to: CGPoint(x: rect.minX + 0.8 * rect.width, y: rect.minY + 0.74 * rect.height))
        return path
    }
}

/// The rise-and-fade the screen underneath does while the splash lifts.
struct SplashRevealModifier: ViewModifier {
    /// How far below its place the screen waits before rising in.
    static let rise: CGFloat = 16
    let revealed: Bool
    /// Hidden from touch-driven tools until the splash lifts: the buttons
    /// exist from the first frame, and a tap aimed at one while the cream
    /// still covers it lands on the splash instead.
    let interactive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Not there to VoiceOver or UI tests until the splash lifts: the
            // buttons exist from the first frame, and a tap aimed at one
            // while the mark is still drawing lands on the splash instead.
            .accessibilityHidden(!interactive)
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : Self.rise)
            .animation(.easeOut(duration: 0.4), value: revealed)
    }
}
