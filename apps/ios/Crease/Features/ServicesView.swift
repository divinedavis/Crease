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
                            tile(id: kind.rawValue, title: kind.label, detail: kind.prompt, symbol: kind.symbol, badge: nil, index: i) {
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
                                symbol: option.symbol,
                                badge: option.isRecommended ? "Best value" : nil,
                                index: i + 3
                            ) {
                                start(BookingIntent(tierId: option.id))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("Services")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 12, content: content)
        }
    }

    private func tile(
        id: String, title: String, detail: String, symbol: String, badge: String?, index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.tag, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("service-tile-\(id)")
        .staggeredAppear(index)
    }
}
