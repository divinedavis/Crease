import XCTest

/// UI tests for the customer app.
///
/// Signed-in screens are reached by injecting a real session minted by
/// scripts/ios-session.mjs (DEBUG-only launch arguments), because neither
/// Apple sign-in nor an emailed code can complete inside a simulator. The
/// session is genuine, so every query below still runs through RLS — these
/// tests exercise the real data path, not a stub.
final class CreaseUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false

        // Dismiss system alerts that would otherwise swallow taps. A stale
        // "Save Password?" left by another app's run on the same simulator is
        // enough to fail an unrelated test, and the failure looks like the
        // screen under test never appeared.
        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            for label in ["Not Now", "Cancel", "Don't Allow", "Allow", "OK", "Continue"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    private func launch(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if !signedIn {
            // Explicit, because the keychain session survives reinstall and
            // would otherwise carry over from a signed-in test.
            app.launchArguments += ["-uiTestSignedOut"]
        }
        if signedIn {
            let access = ProcessInfo.processInfo.environment["UITEST_ACCESS_TOKEN"] ?? ""
            let refresh = ProcessInfo.processInfo.environment["UITEST_REFRESH_TOKEN"] ?? ""
            XCTAssertFalse(access.isEmpty, "UITEST_ACCESS_TOKEN not set — run scripts/ios-test.sh")
            app.launchArguments += [
                "-uiTestAccessToken", access,
                "-uiTestRefreshToken", refresh,
            ]
        }
        app.launch()
        return app
    }

    /// Find a button whether it is in the app or inside a presented sheet.
    ///
    /// confirmationDialog puts its buttons under the sheet, and a cancel-role
    /// button can land in either place depending on presentation. Checking
    /// `.exists` on one and falling back without waiting races the animation
    /// and reports a button that is simply not on screen *yet* as missing.
    private func button(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 6) -> XCUIElement? {
        let candidates = [app.sheets.buttons[label], app.alerts.buttons[label], app.buttons[label]]
        for candidate in candidates where candidate.waitForExistence(timeout: timeout / 3) {
            return candidate
        }
        return nil
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSignInOffersBothProvidersAndNoEmailPath() {
        let app = launch(signedIn: false)

        XCTAssertTrue(app.staticTexts["Crease"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Continue with Apple"].exists
                      || app.buttons["Sign in with Apple"].exists,
                      "Apple is the primary sign-in and must be present")
        XCTAssertTrue(app.buttons["Continue with Google"].exists,
                      "Google is the only alternative, so it must be present")

        // Deliberately asserting an absence. With no email path there is no
        // fallback if a provider breaks, so a stray email field reappearing
        // would quietly reintroduce the inbox round trip the product rejects.
        XCTAssertFalse(app.textFields["Email address"].exists,
                       "no email sign-in: nothing should send a customer to their inbox")
        XCTAssertEqual(app.textFields.count, 0, "the sign-in screen takes no typed input")

        attach(app, "sign-in")
    }

    /// Nothing may interrupt the order list on arrival. The Face ID lock was
    /// briefly offered here in an alert and pulled the same day; this is the
    /// regression test for its absence, and it guards the next prompt anyone
    /// is tempted to put between opening the app and booking a pickup.
    func testNothingIsPromptedOnArrivingAtTheOrderList() {
        let app = launch(signedIn: true)
        XCTAssertTrue(
            app.navigationBars["Crease"].waitForExistence(timeout: 20),
            "signed-in customer should land on the order list"
        )
        XCTAssertFalse(
            app.alerts.element(boundBy: 0).waitForExistence(timeout: 5),
            "arriving at the order list must not raise an alert, got \(app.alerts.element(boundBy: 0).label)"
        )
    }

    /// The privacy cover has to come back down.
    ///
    /// It is an opaque window the app raises over itself whenever it stops
    /// being frontmost, and it used to be lowered on a SwiftUI `scenePhase`
    /// change — a signal another window in front of the app can stop
    /// delivering. When that happened the customer was left staring at a black
    /// screen with a padlock and no way out but backgrounding the app.
    ///
    /// Asserting the cover is absent, rather than that the app is visible: the
    /// cover is its own window, so everything beneath it stays in the
    /// accessibility tree and a plain existence check passes while the screen
    /// is black.
    func testTheAppIsNotCoveredAfterReturningFromTheBackground() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        let cover = app.descendants(matching: .any)["privacy-cover"]

        // Twice: the report was of an intermittent cover, and the first resume
        // can succeed on a window the second one then leaves behind.
        for pass in 1...2 {
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(
                app.buttons["Book a pickup"].waitForExistence(timeout: 15),
                "the order list did not come back after resume \(pass)"
            )
            XCTAssertFalse(
                cover.waitForExistence(timeout: 3),
                "the privacy cover is still up after resume \(pass) — the app is a black screen"
            )
        }
        attach(app, "after-resume")
    }

    func testSignedInCustomerSeesTheirOrders() {
        let app = launch(signedIn: true)

        XCTAssertTrue(
            app.navigationBars["Crease"].waitForExistence(timeout: 20),
            "signed-in customer should land on the order list"
        )
        XCTAssertTrue(app.buttons["Book a pickup"].exists,
                      "the booking entry point moved to the top of the list")
        attach(app, "orders-list")
    }

    func testOrderDetailShowsTheJourney() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        // Open whichever order is at the top of the list.
        let firstCard = app.scrollViews.buttons.firstMatch
        guard firstCard.waitForExistence(timeout: 10) else {
            XCTFail("no orders to open — run scripts/seed.mjs first")
            return
        }
        firstCard.tap()

        XCTAssertTrue(
            app.staticTexts["What they counted"].waitForExistence(timeout: 10)
                || app.otherElements.matching(identifier: "Progress").count > 0
                || app.scrollViews.firstMatch.exists,
            "order detail should render"
        )
        attach(app, "order-detail")
    }

    /// The address row has to name the legs the order actually bought.
    ///
    /// Real order 9864CA was `pickup_only` — one courier, to the shop, and the
    /// customer collects — and the screen still headed its address "Pickup &
    /// delivery", promising a driver who was never paid for.
    func testTheAddressRowNamesOnlyTheLegsTheOrderBought() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        let card = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'cleaner' OR label CONTAINS[c] 'Pickup scheduled'")
        ).firstMatch
        guard card.waitForExistence(timeout: 10) else {
            throw XCTSkip("no seeded order to open — run scripts/seed.mjs first")
        }
        card.tap()
        sleep(3)

        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let onScreen = labels.prefix(16).joined(separator: " | ")
        guard let tier = labels.first(where: {
            ["Round trip", "Pickup only", "Return only"].contains($0)
        }) else {
            return XCTFail("the detail screen should say which service was bought: \(onScreen)")
        }

        // An order with no address on file draws no row at all, which is not
        // this test's business.
        let heads = ["Pickup & delivery", "Pickup address", "Delivery address"]
        guard let shown = labels.first(where: { heads.contains($0) }) else {
            throw XCTSkip("this order has no address row: \(onScreen)")
        }
        let expected = switch tier {
        case "Pickup only": "Pickup address"
        case "Return only": "Delivery address"
        default: "Pickup & delivery"
        }
        XCTAssertEqual(shown, expected, "a \(tier) order headed its address \"\(shown)\"")
        attach(app, "detail-service-tier")
    }

    /// A courier who finished has to leave something on the screen.
    ///
    /// The courier card describes the live leg only, so on order 2232C4 — whose
    /// pickup leg was driven all the way to `delivered` — the entire journey
    /// was represented by one green segment and no words.
    func testACompletedPickupIsReportedOnTheDetailScreen() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        // Matched on the at-the-cleaner wording specifically: a bag that is at
        // the shop got there somehow, and on every tier but return-only a
        // courier is what took it.
        let card = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'counting your items'")
        ).firstMatch
        guard card.waitForExistence(timeout: 10) else {
            throw XCTSkip("no order sitting at the cleaner to open. Cards: "
                + app.buttons.allElementsBoundByIndex.prefix(8).map(\.label)
                    .joined(separator: " ||| "))
        }
        card.tap()
        sleep(3)

        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let onScreen = labels.prefix(20).joined(separator: " | ")
        guard !labels.contains("Return only") else {
            throw XCTSkip("return-only: the customer carried it in, no courier to report")
        }

        XCTAssertTrue(
            labels.contains(where: { $0.hasPrefix("Dropped off at") }),
            "a bag at the shop was delivered there by a driver, and the screen should say so: \(onScreen)"
        )
        attach(app, "completed-leg-detail")
    }

    func testBookingFlowStartsFromTheAddressEntry() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        // The entry point is a search-looking button at the top, not a bar at
        // the bottom — the flow now starts where the eye lands.
        let entry = app.buttons["Book a pickup"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "home should offer a way to book")
        // Do NOT app.tap() to prime the interruption monitor: that taps the
        // centre of the screen, which lands on an order card and navigates
        // away, and the resulting failure claims the button does not exist.
        entry.tap()

        // Screenshot before asserting, so a failure shows what actually
        // appeared rather than only that something did not.
        sleep(3)
        attach(app, "after-tap")
        if !app.navigationBars["Pickup address"].waitForExistence(timeout: 10) {
            XCTFail("address entry did not present. On screen: "
                    + app.navigationBars.allElementsBoundByIndex.map(\.identifier).joined(separator: ",")
                    + " | buttons: "
                    + app.buttons.allElementsBoundByIndex.prefix(8).map(\.identifier).joined(separator: ","))
        }
        XCTAssertTrue(app.textFields["Street address"].exists,
                      "the keyboard target must be present and focused")
        attach(app, "address-entry")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 10),
                      "cancelling returns home rather than stranding the flow")
    }

    // MARK: - Flows that shipped without coverage

    func testCleanerCanBeChanged() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        app.buttons["Book a pickup"].tap()
        XCTAssertTrue(app.navigationBars["Pickup address"].waitForExistence(timeout: 10))

        // The saved home address is the fast path into booking.
        let home = app.buttons.containing(.staticText, identifier: "Home").firstMatch
        guard home.waitForExistence(timeout: 8) else {
            app.buttons["Cancel"].tap()
            throw XCTSkip("no saved address seeded; run scripts/seed.mjs")
        }
        home.tap()

        // The whole point of this row: the app picks a default, the customer
        // overrides it. Before this existed the nearest shop was silently
        // imposed, which is fine with one partner and wrong with two.
        let change = app.buttons.containing(.staticText, identifier: "Change").firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 15), "cleaner must be changeable")
        change.tap()

        XCTAssertTrue(app.navigationBars["Choose a cleaner"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.cells.count + app.buttons.count, 1, "partners should be listed")
        attach(app, "cleaner-picker")
        app.buttons["Cancel"].tap()
    }

    /// The customer picks the service, then says what is in the bag.
    ///
    /// The booking screen used to collect a bare piece count and send an
    /// estimate of zero, so the shop learned what was coming only by opening
    /// the bag, and the hold was too small for any real cleaning bill. Both
    /// halves are asserted here: that the shop's own prices are on screen, and
    /// that laundry is offered by the pound with its minimum spelled out.
    func testTheCustomerPicksAServiceAndSeesTheShopsPrices() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        app.buttons["Book a pickup"].tap()
        XCTAssertTrue(app.navigationBars["Pickup address"].waitForExistence(timeout: 10))

        let home = app.buttons.containing(.staticText, identifier: "Home").firstMatch
        guard home.waitForExistence(timeout: 8) else {
            app.buttons["Cancel"].tap()
            throw XCTSkip("no saved address seeded; run scripts/seed.mjs")
        }
        home.tap()

        let serviceRow = app.buttons.containing(.staticText, identifier: "Dry cleaning").firstMatch
        XCTAssertTrue(serviceRow.waitForExistence(timeout: 15), "the booking screen must offer the service")
        serviceRow.tap()

        XCTAssertTrue(app.navigationBars["Your order"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["What are you sending?"].waitForExistence(timeout: 5),
            "dry cleaning is counted in garments, and the prompt should say so"
        )
        // Prices come from the shop that was picked, not a Crease price list.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' each'")).firstMatch.exists,
            "per-piece prices must be on screen"
        )
        attach(app, "service-menu-dry-clean")

        // Laundry is the other half: sold by weight, with a floor the customer
        // has to be told about before the bag is weighed, not after.
        let laundry = app.buttons["Wash & fold"]
        if laundry.waitForExistence(timeout: 5) {
            laundry.tap()
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS '/ lb'")).firstMatch
                    .waitForExistence(timeout: 5),
                "laundry must be priced by the pound"
            )
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'minimum'")).firstMatch.exists,
                "the weight minimum is the most surprising number in laundry pricing — say it"
            )
            attach(app, "service-menu-wash-fold")
        }

        app.buttons["Done"].tap()
    }

    func testBookingQuotesOnlyTheDriverEta() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))
        app.buttons["Book a pickup"].tap()
        XCTAssertTrue(app.navigationBars["Pickup address"].waitForExistence(timeout: 10))

        let home = app.buttons.containing(.staticText, identifier: "Home").firstMatch
        guard home.waitForExistence(timeout: 8) else {
            app.buttons["Cancel"].tap()
            throw XCTSkip("no saved address seeded")
        }
        home.tap()

        XCTAssertTrue(app.staticTexts["Round trip"].waitForExistence(timeout: 15))

        // Guards a claim the app used to make and cannot support: no estimate
        // here may describe the whole cycle, because the cleaning duration is
        // the shop's to state and it has not been asked yet.
        let allText = app.staticTexts.allElementsBoundByIndex.map(\.label)
        for label in allText where label.contains("min") {
            XCTAssertTrue(
                label.lowercased().contains("driver"),
                "'\(label)' quotes a duration that is not the driver's arrival"
            )
        }
        attach(app, "tiers")
    }

    /// The whole point of the booking screen: it takes money.
    ///
    /// The sheet used to be handed to SwiftUI as state and presented by
    /// `.paymentSheet(isPresented:)` from inside a `.background { if let
    /// sheet ... }`, so the presenter was installed in the same update that
    /// already had the binding true. There was no false→true edge left to
    /// observe, nothing appeared, and the customer sat on the booking screen
    /// forever. Nothing about that shows up in a build log or a unit test —
    /// only driving the button does.
    func testBookingPresentsThePaymentSheet() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))
        app.buttons["Book a pickup"].tap()
        XCTAssertTrue(app.navigationBars["Pickup address"].waitForExistence(timeout: 10))

        let home = app.buttons.containing(.staticText, identifier: "Home").firstMatch
        guard home.waitForExistence(timeout: 8) else {
            app.buttons["Cancel"].tap()
            throw XCTSkip("no saved address seeded; run scripts/seed.mjs")
        }
        home.tap()

        // "Book a pickup" opened this flow; the continue button carries the
        // whole price, which is what tells the two apart.
        let proceed = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Continue' AND label CONTAINS '$'"))
            .firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 15), "booking must offer a priced continue button")
        proceed.tap()

        // The bill, before any money moves. One charge covers the cleaning and
        // the couriers, so both have to be on screen before the card is taken.
        XCTAssertTrue(app.navigationBars["Checkout"].waitForExistence(timeout: 10),
                      "continuing must reach an itemised checkout, not a charge")
        // "Pay $39.43" once the bag is itemised; "Place order · $16.95 +
        // cleaning" when it is not, because a bag nobody priced has no total to
        // promise — only the courier fee is known before the shop counts.
        let pay = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Pay $' OR label BEGINSWITH 'Place order'"))
            .firstMatch
        XCTAssertTrue(pay.waitForExistence(timeout: 5), "checkout must offer a priced action button")
        attach(app, "checkout")
        pay.tap()

        // Stripe mints the intent and loads the sheet over the network, so this
        // is slow by nature. It either arrives or the flow is dead — which is
        // precisely the failure being guarded.
        let payButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Pay $'"))
            .firstMatch
        let appeared = payButton.waitForExistence(timeout: 45)
            || app.textFields["Card number"].waitForExistence(timeout: 5)
            || app.staticTexts["Card information"].waitForExistence(timeout: 5)
        attach(app, "payment-sheet")

        // Stripe's sheet grows from the bottom by an amount only Stripe decides,
        // so the bill lives at the top of a screen of its own. It has to still
        // be readable with the sheet up — that is the whole reason checkout is
        // not a card floating over the map.
        XCTAssertTrue(
            app.staticTexts["Total"].waitForExistence(timeout: 10),
            "the itemised total must be visible behind the payment sheet"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'courier'")).firstMatch.exists,
            "the bill must name the courier line, not just a total"
        )

        XCTAssertTrue(
            appeared,
            "payment sheet never presented. Buttons: "
                + app.buttons.allElementsBoundByIndex.prefix(10).map(\.label).joined(separator: " | ")
                + " · texts: "
                + app.staticTexts.allElementsBoundByIndex.prefix(10).map(\.label).joined(separator: " | ")
        )
    }

    /// What the screen says once the bag is at the shop.
    ///
    /// It used to lead with the pickup window, which by then is a time the
    /// customer already watched happen, and told them to call the cleaner
    /// without giving them the number. Both are the same failure: a screen
    /// that is accurate and answers nothing.
    func testAtTheCleanerItSaysWhenItIsReadyAndHowToCallTheShop() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        // Prefer an order that is actually at the shop, because that is where
        // the two rows swap over. Any order still proves the rest: the seeded
        // data does not always have one parked there, and a test that only
        // skips guards nothing. Matched by status text rather than by position
        // — the first button in the scroll view is "Book a pickup", and tapping
        // that asserts against the address form instead.
        let atCleaner = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'At the cleaner' OR label CONTAINS[c] 'counting your items'")
        ).firstMatch
        let anyOrder = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'cleaner' OR label CONTAINS[c] 'Pickup scheduled'")
        ).firstMatch
        let card = atCleaner.waitForExistence(timeout: 10) ? atCleaner : anyOrder
        guard card.waitForExistence(timeout: 10) else {
            throw XCTSkip("no seeded order to open — run scripts/seed.mjs first")
        }
        card.tap()
        sleep(3)

        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let onScreen = labels.prefix(14).joined(separator: " | ")
        // Read off the detail screen rather than off the card: a card's own
        // label is an aggregate of its children and not reliably the status.
        let isAtCleaner = labels.contains("At the cleaner")

        if isAtCleaner {
            XCTAssertFalse(
                labels.contains("Pickup window"),
                "the courier already delivered it; that window is in the past. On screen: \(onScreen)"
            )
        }

        // The two rows answer the same question at different times, so exactly
        // one of them can be right. Both at once is the bug in its earlier
        // form, still on screen.
        XCTAssertFalse(
            labels.contains("Pickup window") && labels.contains("Ready by"),
            "a pickup window and a ready estimate contradict each other: \(onScreen)"
        )

        // "Ready by" is legitimately absent when the server has no estimate —
        // an older order, or one whose shop has not been reached. What is not
        // allowed is a row that shows a single minute as though the shop had
        // promised one.
        if labels.contains("Ready by") {
            XCTAssertTrue(
                labels.contains { $0.contains("~") && $0.contains("–") },
                "'Ready by' must read as a window: \(onScreen)"
            )
        }

        // Rendered as a Link, which lands in either collection depending on how
        // SwiftUI exposes it, so ask for anything carrying the label.
        let call = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Call '"))
            .firstMatch
        XCTAssertTrue(
            call.waitForExistence(timeout: 8),
            "the shop's number must be present and tappable, not just its name. Buttons: "
                + app.buttons.allElementsBoundByIndex.prefix(10).map(\.label).joined(separator: " | ")
                + " · links: "
                + app.links.allElementsBoundByIndex.prefix(6).map(\.label).joined(separator: " | ")
                + " · texts: \(onScreen)"
        )
        attach(app, "at-cleaner-detail")
    }

    func testCancelIsOfferedAndConfirmed() throws {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))

        // Order cards live inside the scroll view alongside the booking entry,
        // so find one by its status text rather than by position — an index
        // silently shifts the moment anything is added to the list.
        let card = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'cleaner' OR label CONTAINS[c] 'Pickup scheduled'")
        ).firstMatch
        guard card.waitForExistence(timeout: 10) else {
            throw XCTSkip("no seeded order to open — run scripts/seed.mjs")
        }
        card.tap()
        sleep(3)

        // Confirm we actually reached a detail screen before asserting about
        // its contents; otherwise a failed tap reads as a missing feature.
        // The title no longer distinguishes them — both screens say "Crease" —
        // so this asks for a row only the detail screen draws.
        XCTAssertTrue(
            app.staticTexts["Service"].waitForExistence(timeout: 8),
            "tapping an order should push its detail screen"
        )

        // Cancellation is gated on physical custody. Before a courier holds
        // the bag there must be a button; after, there must be an explanation.
        // A screen offering neither is the bug this guards.
        let cancelButton = app.buttons["Cancel this pickup"]
        if cancelButton.waitForExistence(timeout: 8) {
            cancelButton.tap()

            // confirmationDialog presents as an action sheet, whose buttons are
            // children of the sheet rather than of the app. Querying app.buttons
            // alone finds nothing and reads as "no confirmation was shown".
            sleep(2)
            attach(app, "cancel-dialog")

            // Presented as a popover on current iOS, which deliberately drops
            // the cancel-role button — dismissal is a tap outside. So assert
            // what is actually on screen: the destructive action, and the
            // sentence telling the customer whether this will cost them.
            XCTAssertNotNil(
                button("Cancel pickup", in: app),
                "cancelling is irreversible, so it must be confirmed"
            )
            // The wording moved when the courier fee started being taken at
            // booking: "you won't be charged" is only true of a draft now, and
            // the rest depends on how far the order got. What must not change
            // is that the dialog says which of them this is — a refund, a
            // cancellation fee, or a fee that is already spent.
            let explained = app.staticTexts.allElementsBoundByIndex.contains {
                $0.label.contains("costs you nothing")
                    || $0.label.contains("comes back to you")
                    || $0.label.contains("that trip is charged")
                    || $0.label.contains("isn't refunded automatically")
                    || $0.label.contains("cancellation fee is kept")
            }
            XCTAssertTrue(explained, "the confirmation must say whether cancelling costs anything")
            attach(app, "cancel-confirm")

            // Dismiss without cancelling: tap well away from the popover.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        } else {
            let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
            let explained = labels.contains {
                $0.contains("no longer be cancelled")
                    || $0.contains("with a driver")
                    || $0.contains("at the shop")
                    || $0.contains("Cleaning has started")
            }
            XCTAssertTrue(
                explained,
                "no cancel button and no reason. On screen: \(labels.prefix(8).joined(separator: " | "))"
            )
        }
    }
}
