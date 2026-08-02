import MapKit
import SwiftUI

/// Address entry — the first step of booking a pickup.
///
/// Full screen with the keyboard already up, because the only thing anyone
/// does on this screen is type. Saved addresses sit above the suggestions so a
/// returning customer books in one tap without typing at all, which is the
/// common case and should be the fastest one.
struct AddressEntryView: View {
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = AddressSearch()
    @FocusState private var focused: Bool

    let onPicked: (ResolvedAddress) -> Void
    let onPickedSaved: (Address) -> Void

    @State private var resolving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field

                List {
                    if search.query.isEmpty && !store.addresses.isEmpty {
                        Section {
                            ForEach(store.addresses) { address in
                                Button {
                                    onPickedSaved(address)
                                    dismiss()
                                } label: {
                                    savedRow(address)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(search.results, id: \.self) { result in
                        Button {
                            Task { await pick(result) }
                        } label: {
                            suggestionRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if search.query.isEmpty && store.addresses.isEmpty {
                        ContentUnavailableView(
                            "Where should we collect from?",
                            systemImage: "mappin.and.ellipse",
                            description: Text("Start typing your address.")
                        )
                    }
                }
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
                // Bias suggestions to the service area rather than the whole US.
                search.setRegion(MKCoordinateRegion(
                    center: .brooklyn,
                    span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
                ))
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

    private func savedRow(_ address: Address) -> some View {
        HStack(spacing: 14) {
            Image(systemName: address.label?.lowercased() == "work" ? "briefcase.fill" : "house.fill")
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(address.label ?? "Saved").font(.body.weight(.medium))
                Text(address.oneLine).font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func suggestionRow(_ result: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
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
