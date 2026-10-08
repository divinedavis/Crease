import SwiftUI
import UIKit

/// The "Account" tab (2026-10-08): the name large at the top, the everyday
/// controls as a grid of tiles under it, the irreversible ones last. These
/// used to be a menu behind a person icon on the orders screen.
struct AccountView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: OrderStore
    @EnvironmentObject private var lock: AppLock
    @Environment(\.openURL) private var openURL

    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    @State private var exporting = false
    @State private var exportFile: ExportFile?
    // Held separately so it can be deleted in the sheet's onDismiss: the item
    // binding is already nil by the time that fires.
    @State private var lastExportURL: URL?
    @State private var exportError: String?

    /// The finished export, identified by where it was written so the sheet
    /// presents once per file rather than once per tap.
    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    LazyVGrid(columns: columns, spacing: 12) {
                        tile("Help", symbol: "questionmark.circle.fill", index: 0) {
                            if let url = URL(string: "mailto:divinejdavis@gmail.com?subject=Crease%20help") { openURL(url) }
                        }
                        tile("Privacy", symbol: "hand.raised.fill", index: 1) {
                            if let url = URL(string: "https://creasenyc.com/privacy.html") { openURL(url) }
                        }
                        if lock.biometry != .none {
                            tile(
                                lock.isEnabled ? "\(lock.biometry.label) on" : "\(lock.biometry.label) lock",
                                symbol: lock.isEnabled ? "lock.fill" : "lock.open.fill",
                                index: 2
                            ) {
                                Task { await lock.setEnabled(!lock.isEnabled) }
                            }
                            .accessibilityLabel(lock.isEnabled
                                ? "Turn off \(lock.biometry.label) lock"
                                : "Lock with \(lock.biometry.label)")
                        }
                        // The other half of "delete my account": people are
                        // entitled to a copy of what we hold on them, and it
                        // is all readable under their own session anyway.
                        tile(exporting ? "Preparing…" : "Your data", symbol: "square.and.arrow.down.fill", index: 3) {
                            Task { await performExport() }
                        }
                        .disabled(exporting)
                        .accessibilityLabel(exporting ? "Preparing…" : "Download my data")
                    }

                    if !store.addresses.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Saved places")
                                .font(.title3.weight(.bold))
                                .padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(store.addresses) { place in
                                HStack(spacing: 14) {
                                    Image(systemName: place.symbol)
                                        .foregroundStyle(Theme.ink)
                                        .frame(width: 36, height: 36)
                                        .background(Theme.surface, in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.label ?? place.line1).font(.subheadline.weight(.semibold))
                                        Text(place.oneLine).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }

                    VStack(spacing: 0) {
                        row("Sign out", symbol: "rectangle.portrait.and.arrow.right", role: nil) {
                            Task { await session.signOut() }
                        }
                        Divider().padding(.leading, 44)
                        row(deleting ? "Deleting…" : "Delete account", symbol: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                        .disabled(deleting)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Theme.canvas)
            // Deleting is irreversible and takes the order history with it, so
            // it is asked for twice: once to open this, once to confirm. Apple
            // requires the confirmation, and so does anyone who has fat-fingered
            // a button.
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Keep my account", role: .cancel) {}
            } message: {
                Text(
                    "This permanently deletes your orders, saved addresses and account details. It cannot be undone."
                )
            }
            .alert(
                "Account not deleted",
                isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
            ) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .sheet(item: $exportFile, onDismiss: {
                // The share sheet is done: delete the PII export rather than
                // leaving it in tmp for iOS to purge whenever it chooses.
                if let url = lastExportURL {
                    try? FileManager.default.removeItem(at: url)
                    lastExportURL = nil
                }
            }) { file in
                ShareSheet(url: file.url)
            }
            .alert(
                "Couldn't prepare your data",
                isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .task { if store.profile == nil { await store.loadProfile() } }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let phone = store.profile?.formattedPhone {
                    Text(phone)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
        .padding(.top, 8)
    }

    private var displayName: String {
        let name = store.profile?.fullName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Your account" : name
    }

    private func tile(_ title: String, symbol: String, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .staggeredAppear(index)
    }

    private func row(_ title: String, symbol: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).frame(width: 28)
                Text(title).font(.body)
                Spacer()
            }
            .foregroundStyle(role == .destructive ? Theme.danger : Theme.ink)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Success needs no message: the account is gone and `Session` has already
    /// flipped to signed-out, so this view is replaced by the sign-in screen
    /// while the dialog is still dismissing.
    private func performDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await session.deleteAccount()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Gather the account's data and hand it to the share sheet.
    private func performExport() async {
        exporting = true
        defer { exporting = false }
        do {
            let url = try await store.exportAccountData()
            lastExportURL = url
            exportFile = ExportFile(url: url)
        } catch {
            exportError = "We couldn't put your data together just now. Please try again."
        }
    }
}

/// UIKit's share sheet, because `ShareLink` needs its item before the tap and
/// this one only exists after a round trip to the database.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}
