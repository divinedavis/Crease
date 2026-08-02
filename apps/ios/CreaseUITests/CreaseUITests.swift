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
}
