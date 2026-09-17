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
    /// The clock this screen reasons about, fixed when it opens.
    ///
    /// Read from `Date()` inside the computed properties below it would be
    /// re-read on every redraw, so a window could stop being offered midway
    /// through choosing it — and the selection would snap somewhere else under
    /// the customer's finger.
    @State private var now = Date()

    /// Deliberately wide windows. A courier is dispatched at the start of one,
    /// and a narrow promise we cannot keep is worse than an honest range.
    private let windows: [(label: String, start: Int, end: Int)] = [
        ("Morning", 9, 12),
        ("Afternoon", 12, 17),
        ("Evening", 17, 20),
    ]

    /// When a window closes on a given day, which is what decides whether it
    /// can still be booked.
    private func closing(_ index: Int, on day: Date) -> Date? {
        Calendar.current.date(bySettingHour: windows[index].end, minute: 0, second: 0, of: day)
    }

    /// The windows still open on a day — the only ones worth offering.
    ///
    /// The dispatcher refuses a window that has already closed, in those words
    /// ("That delivery time has already passed"), and this screen used to open
    /// on Morning whatever time it was: every afternoon, the first tap on
    /// Confirm was a red error under a control that had offered the choice.
    private func openWindows(on day: Date) -> [Int] {
        windows.indices.filter { (closing($0, on: day) ?? .distantPast) > now }
    }

    /// The first day with anything left to offer. Past the last window, that is
    /// tomorrow — and the date picker must not start before it, or the calendar
    /// opens on a day with no windows in it.
    private var earliestDay: Date {
        openWindows(on: now).isEmpty
            ? Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            : now
    }

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
                    DatePicker("Day", selection: $day, in: earliestDay..., displayedComponents: .date)
                    Picker("Window", selection: $windowIndex) {
                        ForEach(openWindows(on: day), id: \.self) { i in
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
            .onAppear {
                // Open on something bookable: the earliest day that has a
                // window left, and the earliest window left on it.
                now = Date()
                day = earliestDay
                windowIndex = openWindows(on: day).first ?? 0
            }
            // Moving to another day can strip the selected window out of the
            // control — today's Evening does not exist on a day that offers
            // Morning first — and a Picker whose selection matches no tag shows
            // nothing at all.
            .onChange(of: day) {
                if !openWindows(on: day).contains(windowIndex) {
                    windowIndex = openWindows(on: day).first ?? 0
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
        // A sheet can sit open across the end of the window it is offering.
        // Caught here rather than by the dispatcher so the answer names the
        // problem instead of reporting that the booking failed.
        guard end > Date() else {
            error = "That window has closed. Pick a later one."
            now = Date()
            return
        }

        if let message = await store.scheduleReturn(order: order, start: start, end: end) {
            error = message
        } else {
            dismiss()
        }
    }
}
