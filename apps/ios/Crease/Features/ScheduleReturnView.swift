import SwiftUI

/// Choosing when the cleaned clothes come back.
///
/// This screen exists because nobody could have answered this question at
/// booking time. The shop decides when the work is done; only once it says so
/// can the customer pick a window that suits them. Guessing a return slot days
/// in advance — which is what a single "round trip, ~30 min" implied — is
/// either wrong or ignored.
struct ScheduleReturnView: View {
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss

    let order: Order

    @State private var day = Date()
    @State private var windowIndex = 0
    @State private var submitting = false
    @State private var error: String?

    /// Deliberately wide windows. A courier is dispatched at the start of one,
    /// and a narrow promise we cannot keep is worse than an honest range.
    private let windows: [(label: String, start: Int, end: Int)] = [
        ("Morning", 9, 12),
        ("Afternoon", 12, 17),
        ("Evening", 17, 20),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your order is ready")
                                .font(.headline)
                            Text("\(order.cleaner?.name ?? "The shop") finished \(readyAgo).")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    DatePicker("Day", selection: $day, in: Date()..., displayedComponents: .date)
                    Picker("Window", selection: $windowIndex) {
                        ForEach(windows.indices, id: \.self) { i in
                            Text(windows[i].label).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("When should we bring it back?")
                } footer: {
                    Text("A driver collects from \(order.cleaner?.name ?? "the shop") and delivers within this window. You'll get a notification when they're on the way.")
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("Schedule delivery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "…" : "Confirm") { Task { await submit() } }
                        .disabled(submitting)
                }
            }
        }
    }

    private var readyAgo: String {
        guard let readyAt = order.readyAt else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: readyAt, relativeTo: Date())
    }

    private func submit() async {
        submitting = true
        error = nil
        defer { submitting = false }

        let calendar = Calendar.current
        let window = windows[windowIndex]
        guard let start = calendar.date(bySettingHour: window.start, minute: 0, second: 0, of: day),
              let end = calendar.date(bySettingHour: window.end, minute: 0, second: 0, of: day)
        else {
            error = "Couldn't work out that time."
            return
        }

        if let message = await store.scheduleReturn(order: order, start: start, end: end) {
            error = message
        } else {
            dismiss()
        }
    }
}
