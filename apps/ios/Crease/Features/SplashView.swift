import SwiftUI

/// Launch splash, modelled on Lyft's.
///
/// The wordmark sits alone on a plain screen for a beat. When the app knows
/// where it is going, the letters fold away one at a time from the left — each
/// squeezes into a thin vertical bar and vanishes, the last bar shrinks to a
/// point — while the screen underneath fades up and settles into place.
///
/// The fold is the "we're ready" signal, not a timer: `ready` is the auth gate
/// having resolved. A slow keychain read keeps the mark on screen rather than
/// folding it away to reveal a spinner, which is what the two-second static
/// logo in Lyft's own launch is doing. A short minimum hold stops a fast launch
/// from folding a mark nobody had time to see.
///
/// Reduce Motion gets a plain crossfade: the squeeze is the kind of motion
/// that setting exists to switch off.
struct SplashView: View {
    /// True once the screen behind this one is the real one.
    let ready: Bool
    /// The background of that screen, so the dim lands on it exactly: the
    /// order list sits on grouped grey, sign-in on plain white.
    let dimsTo: Color
    /// Fired as the overlay starts lifting, so the screen underneath can rise
    /// into view while the last bar is still shrinking.
    let onReveal: () -> Void
    /// Fired once, after the last frame, so the owner can drop the overlay.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let letters = Array("crease")
    /// How long the mark stays up even on an instant launch.
    private static let minimumHold: TimeInterval = 0.7
    /// Gap between one letter starting to fold and the next.
    private static let stagger: TimeInterval = 0.07
    private static let fold: TimeInterval = 0.2
    private static let reveal: TimeInterval = 0.32

    @State private var heldLongEnough = false
    /// `ready` as last seen. The `.task` closure below captures the view value
    /// it was created with, so reading `ready` from inside it after the hold
    /// gives the value at launch — false — and the fold never plays. State is
    /// read through storage, so it is current.
    @State private var isReady = false
    @State private var exiting = false
    /// Per letter: 0 = upright, 1 = folded to a bar, 2 = gone.
    @State private var stage: [Int] = Array(repeating: 0, count: letters.count)
    @State private var lastBarShrunk = false
    @State private var backgroundOpacity = 1.0

    var body: some View {
        ZStack {
            // Starts as the launch screen's colour so the hand-off from the
            // static launch image is invisible, and dims toward the next
            // screen's own background as the letters start to fold — the same
            // beat where Lyft's white goes dark.
            Color(.systemBackground)
            dimsTo.opacity(exiting ? 1 : 0)

            HStack(spacing: 0) {
                ForEach(Self.letters.indices, id: \.self) { i in
                    let isLast = i == Self.letters.count - 1
                    Text(String(Self.letters[i]))
                        .scaleEffect(
                            x: stage[i] >= 1 ? 0.12 : 1,
                            y: isLast && lastBarShrunk ? 0.14 : 1
                        )
                        .opacity(stage[i] >= 2 ? 0 : 1)
                }
            }
            .font(.system(size: 72, weight: .black, design: .rounded))
            .foregroundStyle(Theme.accent)
            .kerning(-3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Crease")
            .accessibilityIdentifier("splash.wordmark")
        }
        .ignoresSafeArea()
        .opacity(backgroundOpacity)
        .task {
            try? await Task.sleep(for: .seconds(Self.minimumHold))
            heldLongEnough = true
            exitIfDue()
        }
        .onAppear {
            isReady = ready
            exitIfDue()
        }
        .onChange(of: ready) { now in
            isReady = now
            exitIfDue()
        }
    }

    private func exitIfDue() {
        guard isReady, heldLongEnough, !exiting else { return }
        exiting = true

        if reduceMotion {
            onReveal()
            withAnimation(.easeOut(duration: Self.reveal)) { backgroundOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reveal, execute: onFinished)
            return
        }

        let n = Self.letters.count
        for i in 0..<n {
            let start = Double(i) * Self.stagger
            withAnimation(.easeIn(duration: Self.fold).delay(start)) { stage[i] = 1 }
            if i < n - 1 {
                withAnimation(.easeOut(duration: 0.08).delay(start + Self.fold)) { stage[i] = 2 }
            }
        }
        // The last bar lingers, then shrinks to a point and is gone.
        let lastStart = Double(n - 1) * Self.stagger + Self.fold + 0.05
        withAnimation(.easeIn(duration: 0.18).delay(lastStart)) { lastBarShrunk = true }
        withAnimation(.easeOut(duration: 0.1).delay(lastStart + 0.16)) { stage[n - 1] = 2 }

        let revealAt = lastStart + 0.2
        withAnimation(.easeOut(duration: Self.reveal).delay(revealAt)) { backgroundOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + revealAt, execute: onReveal)
        DispatchQueue.main.asyncAfter(deadline: .now() + revealAt + Self.reveal, execute: onFinished)
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
