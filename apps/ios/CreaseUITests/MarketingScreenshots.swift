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
        sleep(2)
        shoot(app, "01-home")

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

        // The cleaner picker — proof the customer chooses their own shop.
        let change = app.buttons.containing(.staticText, identifier: "Change").firstMatch
        if change.waitForExistence(timeout: 6) {
            change.tap()
            if app.navigationBars["Choose a cleaner"].waitForExistence(timeout: 8) {
                sleep(2)
                shoot(app, "04-cleaners")
                app.buttons["Cancel"].tap()
                sleep(1)
            }
        }

        // Out of the booking flow, then into an existing order for the
        // progress track.
        if app.buttons["Back"].firstMatch.exists {
            app.buttons["Back"].firstMatch.tap()
        }
        sleep(2)

        let firstOrder = app.scrollViews.buttons.element(boundBy: 1)
        if firstOrder.waitForExistence(timeout: 8) {
            firstOrder.tap()
            sleep(3)
            shoot(app, "05-tracking")
        }
    }
}
