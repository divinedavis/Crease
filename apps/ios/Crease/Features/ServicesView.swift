import SwiftUI

/// Everything Crease does, as a grid of tiles (the "Services" tab, 2026-10-08).
/// Each tile starts the booking with that choice already made.
struct ServicesView: View {
    let start: (BookingIntent) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Get it cleaned") {
                        ForEach(Array(ServiceKind.allCases.enumerated()), id: \.element.id) { i, kind in
                            tile(id: kind.rawValue, title: kind.label, detail: kind.prompt, art: kind.illustration, badge: nil, index: i) {
                                start(BookingIntent(kind: kind))
                            }
                        }
                    }
                    section("Get it moved") {
                        ForEach(Array(ServiceOption.all.enumerated()), id: \.element.id) { i, option in
                            tile(
                                id: option.id,
                                title: option.name,
                                detail: "From \(option.priceCents.asMoney)",
                                art: option.illustration,
                                badge: option.isRecommended ? "Best value" : nil,
                                index: i + 3
                            ) {
                                start(BookingIntent(tierId: option.id))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle("Services")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(title)
            LazyVGrid(columns: columns, spacing: 12, content: content)
        }
    }

    /// The reference's product card: a white card, the illustration on a
    /// grey tile with a round "+" in its corner, the name and one line under it.
    private func tile(
        id: String, title: String, detail: String, art: Illustration, badge: String?, index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    art.image
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if let badge {
                                Text(badge)
                                    .font(.app(.caption2).weight(.bold))
                                    .foregroundStyle(Theme.onInk)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.ink, in: Capsule())
                                    .padding(8)
                            }
                        }
                    PlusBadge(size: 34).padding(8)
                }
                .padding(.bottom, 6)
                Text(title)
                    .font(.app(.headline))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.app(.caption))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .outlineCard(padding: 10)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("service-tile-\(id)")
        .staggeredAppear(index)
    }
}
