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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        IllustrationTile(art: .folded, size: 88, corner: 26, inset: 0.1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your order is ready")
                                .font(.app(.title3).weight(.bold))
                            Text("\(order.cleaner?.name ?? "The shop") finished \(readyAgo).")
                                .font(.app(.subheadline))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    Eyebrow("When should we bring it back?")
                        .padding(.top, 6)

                    // A week of days as chips, the chosen one black.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(dayChoices, id: \.self) { choice in
                                let on = Calendar.current.isDate(choice, inSameDayAs: day)
                                Button { withAnimation(Motion.snappy) { day = choice } } label: {
                                    VStack(spacing: 2) {
                                        Text(Calendar.current.isDateInToday(choice) ? "Today"
                                             : choice.formatted(.dateTime.weekday(.abbreviated)))
                                            .font(.app(.caption))
                                            .opacity(0.75)
                                        Text(choice.formatted(.dateTime.day()))
                                            .font(.app(.title2).weight(.bold).monospacedDigit())
                                    }
                                    .foregroundStyle(on ? Theme.onInk : Theme.ink)
                                    .frame(width: 66, height: 72)
                                    .background(on ? Theme.ink : Theme.surface,
                                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel(choice.formatted(date: .complete, time: .omitted))
                                .accessibilityAddTraits(on ? [.isSelected] : [])
                            }
                        }
                    }
                    .scrollClipDisabled()

                    VStack(spacing: 10) {
                        ForEach(openWindows(on: day), id: \.self) { i in
                            let on = i == windowIndex
                            Button { withAnimation(Motion.snappy) { windowIndex = i } } label: {
                                HStack(spacing: 14) {
                                    IllustrationTile(art: windowArt[i], size: 52, corner: 16, inset: 0.12)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(windows[i].label).font(.app(.headline))
                                        Text(windowHours(i))
                                            .font(.app(.subheadline))
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.app(.title2))
                                        .foregroundStyle(on ? Theme.ink : Theme.line)
                                }
                                .outlineCard(padding: 12, selected: on)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }

                    Text("A driver collects from \(order.cleaner?.name ?? "the shop") and delivers within this window. You'll get a notification when they're on the way.")
                        .font(.app(.footnote))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error {
                        Text(error)
                            .font(.app(.footnote))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(20)
            }
            .background(Theme.canvas)
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

    private let windowArt: [Illustration] = [.sunrise, .sun, .moon]

    /// Seven days from the first one with a window left.
    private var dayChoices: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: earliestDay) }
    }

    private func windowHours(_ i: Int) -> String {
        func h(_ hour: Int) -> String {
            let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
            return d.formatted(.dateTime.hour())
        }
        return "\(h(windows[i].start)) – \(h(windows[i].end))"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var readyAgo: String {
        guard let readyAt = order.readyAt else { return "just now" }
        return Self.relative.localizedString(for: readyAt, relativeTo: Date())
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
