import XCTest

/// Captures the screens used for App Store marketing panels.
///
/// A UI test rather than `simctl io screenshot` because the interesting
/// screens are behind a session and behind navigation — the address sheet, the
/// tier picker, an order mid-journey. A bare screenshot tool can only ever
/// photograph whatever launched first.
///
/// Not part of the normal suite: it asserts almost nothing and exists to
/// produce artefacts. Run it explicitly.
///
///     ./scripts/marketing-shots.sh
final class MarketingScreenshots: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let access = ProcessInfo.processInfo.environment["UITEST_ACCESS_TOKEN"] ?? ""
        let refresh = ProcessInfo.processInfo.environment["UITEST_REFRESH_TOKEN"] ?? ""
        XCTAssertFalse(access.isEmpty, "run via scripts/marketing-shots.sh")
        app.launchArguments += [
            "-uiTestAccessToken", access,
            "-uiTestRefreshToken", refresh,
        ]
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureMarketingScreens() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 25))

        // Wait for the orders to actually arrive, pulling to refresh between
        // checks. The first load fires from OrdersView's .task and can beat the
        // injected session onto the wire: the request goes out as anon, RLS
        // returns nothing, and the screen settles on "No orders yet" over an
        // account that has three. One swipe was not enough — three runs in a
        // row photographed the empty state — so keep asking.
        let titles = ["Ready for delivery", "Being cleaned", "Pickup scheduled"]
        var listed = false
        for attempt in 0..<8 {
            if titles.contains(where: { app.staticTexts[$0].exists }) {
                listed = true
                break
            }
            if attempt > 0 { app.scrollViews.firstMatch.swipeDown() }
            sleep(4)
        }
        shoot(app, listed ? "01-home" : "09-home-empty")
        XCTAssertTrue(listed, "Orders never loaded — the session was not honoured")

        // The order the shop has finished, taken now rather than after the
        // booking walk: several minutes in, the injected session stops being
        // honoured and Orders empties out again.
        //
        // Tap the status line itself: a NavigationLink wearing .buttonStyle
        // (.plain) does not appear under `app.scrollViews.buttons`, but its
        // text does, and tapping the text follows the link.
        if let card = titles.lazy
            .map({ app.staticTexts[$0].firstMatch })
            .first(where: { $0.exists }) {
            card.tap()
            sleep(4)
            shoot(app, "05-tracking")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(2)
        }

        // Address entry, showing the pinned home row.
        guard app.buttons["Book a pickup"].waitForExistence(timeout: 8) else { return }
        app.buttons["Book a pickup"].tap()
        guard app.navigationBars["Pickup address"].waitForExistence(timeout: 10) else { return }
        sleep(2)
        shoot(app, "02-address")

        // Picking the saved home address skips straight to booking — the fast
        // path, and the screen where the product's actual proposition lives.
        let home = app.buttons.containing(.staticText, identifier: "Home").firstMatch
        if home.waitForExistence(timeout: 6) {
            home.tap()
        } else {
            app.buttons["Cancel"].tap()
            return
        }

        // The booking screen needs a moment: it frames the map and loads the
        // partner list before it looks like anything.
        sleep(6)
        shoot(app, "03-booking")

        // The service menu: the screen that says what the product actually
        // sells — wash & fold by the pound at the shop's own prices. The old
        // fourth panel photographed the cleaner picker under the headline
        // "your shop, not ours", which stopped being true when migration 0043
        // left one real partner.
        let chooseItems = app.buttons["Choose what you're sending"]
        if chooseItems.waitForExistence(timeout: 8) {
            chooseItems.tap()
            if app.navigationBars["Your order"].waitForExistence(timeout: 10) {
                // A menu with nothing chosen totals $0.00, which reads as a
                // broken screen rather than a price list. Put a few pounds in
                // the bag so the estimate line has a number in it.
                let stepper = app.steppers.firstMatch
                if stepper.waitForExistence(timeout: 5) {
                    let increment = stepper.buttons.element(boundBy: 1)
                    for _ in 0..<8 where increment.exists { increment.tap() }
                }
                sleep(1)
                shoot(app, "04-menu")
            }
        }
    }
}
