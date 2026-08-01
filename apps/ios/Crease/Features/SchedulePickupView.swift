import SwiftUI

/// Booking a pickup.
///
/// The estimate here is explicitly a guess and is labelled as one throughout.
/// The real price comes from the shop counting the bag, and pretending
/// otherwise at this screen is what turns a normal repricing into a customer
/// feeling misled two days later.
struct SchedulePickupView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss

    @State private var cleaner: Cleaner?
    @State private var address: Address?
    @State private var menu: [ServiceItem] = []
    @State private var counts: [UUID: Int] = [:]
    @State private var pickupDay = Date()
    @State private var windowIndex = 0
    @State private var notes = ""
    @State private var submitting = false
    @State private var showingAddAddress = false

    private let windows = [
        ("Morning", 9, 12),
        ("Afternoon", 12, 17),
        ("Evening", 17, 20),
    ]

    private var estimateCents: Int {
        menu.reduce(0) { $0 + (counts[$1.id] ?? 0) * $1.unitPriceCents }
    }

    private var canSubmit: Bool {
        cleaner != nil && address != nil && estimateCents > 0 && !submitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cleaner") {
                    Picker("Cleaner", selection: $cleaner) {
                        Text("Choose").tag(Cleaner?.none)
                        ForEach(store.cleaners) { c in
                            Text("\(c.name) · \(c.city)").tag(Cleaner?.some(c))
                        }
                    }
                    if let cleaner {
                        Text("Usually ready in \(cleaner.turnaroundHours) hours")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Pickup address") {
                    if store.addresses.isEmpty {
                        Button("Add an address") { showingAddAddress = true }
                    } else {
                        Picker("Address", selection: $address) {
                            Text("Choose").tag(Address?.none)
                            ForEach(store.addresses) { a in
                                Text(a.label ?? a.line1).tag(Address?.some(a))
                            }
                        }
                        Button("Add another") { showingAddAddress = true }
                            .font(.footnote)
                    }
                }

                Section {
                    DatePicker("Day", selection: $pickupDay, in: Date()..., displayedComponents: .date)
                    Picker("Window", selection: $windowIndex) {
                        ForEach(windows.indices, id: \.self) { i in
                            Text(windows[i].0).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("When")
                } footer: {
                    Text("A driver arrives inside this window. You'll get a notification when they're close.")
                }

                if cleaner != nil {
                    Section {
                        ForEach(menu) { item in
                            Stepper(value: binding(for: item.id), in: 0...50) {
                                HStack {
                                    Text(item.label)
                                    Spacer()
                                    if let n = counts[item.id], n > 0 {
                                        Text("\(n)")
                                            .font(.body.monospacedDigit())
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Text(item.unitPriceCents.asMoney)
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Roughly what's in the bag")
                    } footer: {
                        Text("Just an estimate — you don't have to be exact. The shop counts everything when it arrives and we'll confirm the real price then.")
                    }
                }

                Section("Anything we should know?") {
                    TextField("Stain on the left cuff, no starch…", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    HStack {
                        Text("Estimate").font(.headline)
                        Spacer()
                        Text(estimateCents.asMoney)
                            .font(.headline.monospacedDigit())
                    }
                    Text("We place a hold, not a charge. You're billed once the shop has counted your items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule a pickup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "…" : "Book") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
            .sheet(isPresented: $showingAddAddress) {
                AddAddressView { address = $0 }
            }
            .onChange(of: cleaner) { _, new in
                Task {
                    counts = [:]
                    menu = new.map { _ in [] } ?? []
                    if let id = new?.id { menu = await store.serviceMenu(for: id) }
                }
            }
            .task {
                if store.cleaners.isEmpty { await store.loadCleaners() }
                if store.addresses.isEmpty { await store.loadAddresses() }
                address = store.addresses.first
                cleaner = store.cleaners.first
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Int> {
        Binding(get: { counts[id] ?? 0 }, set: { counts[id] = $0 })
    }

    private func submit() async {
        guard let cleaner, let address, let userId = session.userId else { return }
        submitting = true
        defer { submitting = false }

        let cal = Calendar.current
        let w = windows[windowIndex]
        let start = cal.date(bySettingHour: w.1, minute: 0, second: 0, of: pickupDay) ?? pickupDay
        let end = cal.date(bySettingHour: w.2, minute: 0, second: 0, of: pickupDay) ?? pickupDay

        let created = await store.createOrder(.init(
            customer_id: userId,
            cleaner_id: cleaner.id,
            address_id: address.id,
            status: "scheduled",
            estimate_subtotal_cents: estimateCents,
            pickup_window_start: start,
            pickup_window_end: end,
            customer_notes: notes.isEmpty ? nil : notes
        ))
        if created != nil { dismiss() }
    }
}

struct AddAddressView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss

    let onSaved: (Address) -> Void

    @State private var label = "Home"
    @State private var line1 = ""
    @State private var city = ""
    @State private var state = "NY"
    @State private var postalCode = ""
    @State private var accessNotes = ""
    @State private var saving = false

    private var canSave: Bool {
        !line1.isEmpty && !city.isEmpty && !state.isEmpty && postalCode.count >= 5 && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (Home, Office)", text: $label)
                    TextField("Street address", text: $line1)
                        .textContentType(.streetAddressLine1)
                    TextField("City", text: $city)
                        .textContentType(.addressCity)
                    HStack {
                        TextField("State", text: $state)
                            .textContentType(.addressState)
                            .frame(width: 70)
                        TextField("ZIP", text: $postalCode)
                            .textContentType(.postalCode)
                            .keyboardType(.numberPad)
                    }
                }
                Section {
                    TextField("Buzzer 3R, leave with the doorman…", text: $accessNotes, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("How should the driver reach you?")
                } footer: {
                    // Drivers read this verbatim in their own app; a good note
                    // here is the difference between a handoff and a failed
                    // delivery that has to be re-dispatched.
                    Text("The driver sees this. Buzzer numbers and doorman instructions save a trip.")
                }
            }
            .navigationTitle("Add address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            guard let userId = session.userId else { return }
                            saving = true
                            let saved = await store.addAddress(.init(
                                user_id: userId,
                                label: label.isEmpty ? nil : label,
                                line1: line1,
                                city: city,
                                state: state,
                                postal_code: postalCode,
                                access_notes: accessNotes.isEmpty ? nil : accessNotes
                            ))
                            saving = false
                            if let saved {
                                onSaved(saved)
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
