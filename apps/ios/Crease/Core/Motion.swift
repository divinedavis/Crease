import SwiftUI

/// The app's motion, in one place (2026-10-08, the ride-hailing redesign).
///
/// Everything here does the same three things: answers a touch the instant it
/// lands, eases new content in rather than popping it, and does nothing at all
/// under Reduce Motion — where an animation is a cost, not a courtesy.
enum Motion {
    /// Selection, press and sheet movement: quick, slightly springy.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Content arriving: a softer spring with no overshoot to speak of.
    static let settle = Animation.spring(response: 0.5, dampingFraction: 0.9)
}

/// The primary action: full width, ink fill, square-ish corners.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 16)
            .foregroundStyle(prominent ? Theme.onInk : Theme.ink)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Theme.ink : Theme.surface)
            )
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Tiles and cards: shrink a touch under the finger, the way every tile in a
/// ride-hailing app does, so a tap reads as landing before anything loads.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A light band sweeping across a placeholder while the real content loads.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.18), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Fades and lifts content in on first appearance, delayed by its position so
/// a list arrives top to bottom instead of all at once.
private struct StaggeredAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                // Capped, so row twenty does not wait a second to show up.
                withAnimation(Motion.settle.delay(Double(min(index, 8)) * 0.045)) { shown = true }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

/// A grey block standing in for a row that has not loaded yet.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.surface)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A placeholder list row: square thumbnail and two lines of text.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            SkeletonBlock(width: 52, height: 52, radius: 10)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 170, height: 14)
                SkeletonBlock(width: 110, height: 12)
            }
            Spacer()
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}
