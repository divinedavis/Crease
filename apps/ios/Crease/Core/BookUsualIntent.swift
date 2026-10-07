import AppIntents

/// "Hey Siri, book my usual Crease pickup."
///
/// Opens the app on the booking screen with the usual prefilled — it does not
/// book in the background, because a booking charges a card and the Apple Pay
/// sheet has to be seen and confirmed. With no usual yet, it opens the address
/// step instead of guessing.
struct BookUsualPickupIntent: AppIntent {
    static let title: LocalizedStringResource = "Book My Usual Pickup"
    static let description = IntentDescription("Opens Crease with your usual order ready to check out.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PushRouter.shared.wantsUsual = true
        return .result()
    }
}

struct CreaseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BookUsualPickupIntent(),
            phrases: [
                "Book my usual \(.applicationName) pickup",
                "Schedule my \(.applicationName) pickup",
                "Reorder my \(.applicationName) laundry",
            ],
            shortTitle: "Book My Usual",
            systemImageName: "arrow.clockwise.circle"
        )
    }
}
