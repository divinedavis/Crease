import CoreLocation
import SwiftUI

/// Choose which partner shop the bag goes to.
///
/// Previously the flow silently used whichever shop happened to sort first,
/// which is fine with one partner and wrong the moment there are two — the
/// customer has a shop they trust, and the app was picking for them.
///
/// Ordered by distance from the pickup point because that is the only ordering
/// that means anything to a customer here. Courier cost is essentially flat
/// under three miles, so distance is about convenience and turnaround, not
/// price.
struct CleanerPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let cleaners: [Cleaner]
    let pickup: CLLocationCoordinate2D
    let selected: Cleaner?
    let onPick: (Cleaner) -> Void

    private var sorted: [Cleaner] {
        cleaners.sorted {
            ($0.milesFrom(pickup) ?? .greatestFiniteMagnitude)
                < ($1.milesFrom(pickup) ?? .greatestFiniteMagnitude)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if cleaners.isEmpty {
                    ContentUnavailableView(
                        "No partner cleaners yet",
                        systemImage: "building.2",
                        description: Text("We're signing shops up in your area.")
                    )
                    .listRowSeparator(.hidden)
                }

                ForEach(sorted) { cleaner in
                    Button {
                        onPick(cleaner)
                        dismiss()
                    } label: {
                        row(cleaner)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Choose a cleaner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
            }
        }
    }

    private func row(_ cleaner: Cleaner) -> some View {
        let isSelected = cleaner.id == selected?.id
        return HStack(spacing: 14) {
            Image(systemName: "building.2.fill")
                .font(.body)
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
                .frame(width: 38, height: 38)
                .background(isSelected ? Theme.accentSoft : Color(.tertiarySystemFill), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(cleaner.name).font(.body.weight(.semibold))
                Text([cleaner.line1, cleaner.city].compactMap { $0 }.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let miles = cleaner.milesFrom(pickup) {
                        Label(String(format: "%.1f mi", miles), systemImage: "location")
                    }
                    Label("\(cleaner.turnaroundHours)h turnaround", systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
