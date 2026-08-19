import MapKit
import SwiftUI

/// Address entry — the first step of booking a pickup.
///
/// Two things carry this screen. The home address is pinned as a permanent
/// first row and does not disappear once typing starts, because the most
/// common booking is "the usual place" and it should never require finishing a
/// word. And suggestions are biased to where the customer actually is, so
/// "Bedford" offers the one down the road rather than the one in Ohio.
struct AddressEntryView: View {
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = AddressSearch()
    @StateObject private var location = LocationProvider()
    @FocusState private var focused: Bool

    let onPicked: (ResolvedAddress) -> Void
    let onPickedSaved: (Address) -> Void

    @State private var resolving = false

    /// A short list beats a long one here: the right answer is nearly always
    /// in the first few, and a wall of near-identical streets is harder to
    /// scan than it is helpful.
    private let suggestionLimit = 3

    private var home: Address? {
        store.addresses.first { ($0.label ?? "").lowercased() == "home" }
            ?? store.addresses.first
    }

    private var otherSaved: [Address] {
        store.addresses.filter { $0.id != home?.id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field

                List {
                    // Pinned. Stays put while typing — this is the whole point.
                    if let home {
                        Button {
                            onPickedSaved(home)
                            dismiss()
                        } label: {
                            savedRow(home, pinned: true)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.accentSoft.opacity(0.35))
                    }

                    ForEach(search.results.prefix(suggestionLimit), id: \.self) { result in
                        Button {
                            Task { await pick(result) }
                        } label: {
                            suggestionRow(result)
                        }
                        .buttonStyle(.plain)
                    }

                    if search.query.isEmpty && !otherSaved.isEmpty {
                        Section("Saved") {
                            ForEach(otherSaved) { address in
                                Button {
                                    onPickedSaved(address)
                                    dismiss()
                                } label: {
                                    savedRow(address, pinned: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if search.query.isEmpty && home == nil && otherSaved.isEmpty {
                        Text("Start typing your address.")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }

                    // Where the couriers actually reach, said before somebody
                    // types a street we cannot serve. Three miles from Fulton
                    // Street is most of brownstone Brooklyn and further than
                    // people assume — naming only the two nearest
                    // neighbourhoods sold the area short.
                    if search.query.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Where we collect", systemImage: "mappin.and.ellipse")
                                .font(.footnote.weight(.semibold))
                            Text(ServiceArea.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.plain)
                .animation(.easeOut(duration: 0.18), value: search.results.count)
            }
            .navigationTitle("Pickup address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
            }
            .overlay { if resolving { ProgressView().controlSize(.large) } }
            .task {
                focused = true
                if store.addresses.isEmpty { await store.loadAddresses() }
                // Asked here rather than at launch: the prompt has an obvious
                // purpose at the moment someone is about to type an address.
                location.requestIfNeeded()
                search.setRegion(location.searchRegion)
            }
            .onChange(of: location.coordinate?.latitude) { _, _ in
                // Re-bias as soon as a fix arrives, so the first few keystrokes
                // are not ranked against a stale region.
                search.setRegion(location.searchRegion)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Street address", text: $search.query)
                .focused($focused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Street address")
            if !search.query.isEmpty {
                Button { search.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.accent.opacity(focused ? 0.9 : 0), lineWidth: 2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private func savedRow(_ address: Address, pinned: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: address.symbol)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(address.label ?? "Saved").font(.body.weight(.semibold))
                Text(address.oneLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if pinned {
                Image(systemName: "arrow.up.left.circle.fill")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func suggestionRow(_ result: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.body)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        guard let resolved = await search.resolve(completion) else { return }
        onPicked(resolved)
        dismiss()
    }
}
