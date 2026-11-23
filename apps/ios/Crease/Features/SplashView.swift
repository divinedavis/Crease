import SwiftUI
import UIKit

/// Launch splash: the Pleat mark draws itself (owner's pick, 2026-11-23,
/// option 1 "Draw" of five).
///
/// On the brand's cream, the pleat is drawn in one stroke like a stitch, the
/// pressed line slides out under it from the middle, and "crease" rises into
/// place. When the app knows where it is going, the cream fades away and the
/// mark lifts up and out while the screen underneath rises into view.
///
/// The lift is the "we're ready" signal, not a timer: `ready` is the auth gate
/// having resolved. A slow keychain read keeps the mark on screen rather than
/// lifting it to reveal a spinner. The intro always finishes first, so a fast
/// launch never cuts the drawing off halfway.
///
/// The cream matches the launch screen (the `SplashBackground` colour, which
/// Info.plist's UILaunchScreen also names), so the hand-off from the static
/// launch image is invisible. Reduce Motion gets the finished mark and a plain
/// crossfade.
struct SplashView: View {
    /// True once the screen behind this one is the real one.
    let ready: Bool
    /// Fired as the overlay starts lifting, so the screen underneath can rise
    /// into view while the mark is still going.
    let onReveal: () -> Void
    /// Fired once, after the last frame, so the owner can drop the overlay.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Timings from the approved mock-up (seconds from first frame).
    private static let drawStart: TimeInterval = 0.15
    private static let drawLength: TimeInterval = 0.75
    private static let pressStart: TimeInterval = 0.8
    private static let pressLength: TimeInterval = 0.35
    private static let wordStart: TimeInterval = 1.0
    private static let wordLength: TimeInterval = 0.45
    /// The finished mark stays up a beat before it can lift.
    static let introLength: TimeInterval = 1.8
    /// Reduce Motion skips the drawing, so only a short hold.
    private static let stillHold: TimeInterval = 0.7
    private static let exitLength: TimeInterval = 0.45

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
    @State private var exiting = false
    @State private var drawn: CGFloat = 0
    @State private var pressed: CGFloat = 0
    @State private var wordShown = false
    @State private var lifted = false
    @State private var coverOpacity = 1.0
    @State private var overallOpacity = 1.0

    var body: some View {
        ZStack {
            Color("SplashBackground")
                .opacity(coverOpacity)

            VStack(spacing: 10) {
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

                Text("crease")
                    .font(Font(WordmarkFont.uiFont(size: 46)))
                    .foregroundStyle(Self.wordColor)
                    .opacity(wordShown ? 1 : 0)
                    .offset(y: wordShown ? 0 : 10)
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
            drawn = 1; pressed = 1; wordShown = true
            return
        }
        withAnimation(.timingCurve(0.6, 0, 0.2, 1, duration: Self.drawLength).delay(Self.drawStart)) { drawn = 1 }
        withAnimation(.easeOut(duration: Self.pressLength).delay(Self.pressStart)) { pressed = 1 }
        withAnimation(.easeOut(duration: Self.wordLength).delay(Self.wordStart)) { wordShown = true }
    }

    private func exitIfDue() {
        guard isReady, heldLongEnough, !exiting else { return }
        exiting = true
        onReveal()
        if reduceMotion {
            // A plain crossfade: nothing moves.
            withAnimation(.easeOut(duration: Self.exitLength)) { overallOpacity = 0 }
        } else {
            withAnimation(.easeIn(duration: Self.exitLength)) {
                coverOpacity = 0
                lifted = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitLength, execute: onFinished)
    }
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
    let revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 16)
            .animation(.easeOut(duration: 0.4), value: revealed)
    }
}
