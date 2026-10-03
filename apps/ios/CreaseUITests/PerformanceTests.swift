import XCTest

/// Speed and memory on the paths a customer waits on, added 2026-10-03 with
/// Apple's XCTMetric API. Numbers land in the .xcresult and
/// scripts/ios-perf-gate.py fails the ship when one is more than 1.5x the
/// median of the last five passing ships (apps/ios/perf_baseline.json). A
/// simulator is not a phone: this catches a regression, not a real-world time.
/// Real-phone numbers come from the Xcode Organizer (scripts/organizer-report.py).
final class PerformanceTests: XCTestCase {

    private func app(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if signedIn {
            let env = ProcessInfo.processInfo.environment
            app.launchArguments += ["-uiTestAccessToken", env["UITEST_ACCESS_TOKEN"] ?? "",
                                    "-uiTestRefreshToken", env["UITEST_REFRESH_TOKEN"] ?? ""]
        } else {
            app.launchArguments += ["-uiTestSignedOut"]
        }
        return app
    }

    /// Cold launch to first frame the user can touch.
    func testLaunch() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: opts) {
            app(signedIn: false).launch()
        }
    }

    /// A signed-in launch until the order list is up: session restore plus the
    /// first orders query, i.e. what a returning customer waits through.
    func testLaunchToOrderList() {
        let app = app(signedIn: true)
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: opts) {
            app.launch()
            XCTAssertTrue(app.buttons["Book a pickup"].waitForExistence(timeout: 30))
            app.terminate()
        }
    }

    /// Opening the booking flow, and the memory the app holds once it is open.
    func testOpenBooking() {
        let app = app(signedIn: true)
        app.launch()
        XCTAssertTrue(app.buttons["Book a pickup"].waitForExistence(timeout: 30))
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        opts.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: opts) {
            app.buttons["Book a pickup"].tap()
            XCTAssertTrue(app.navigationBars["Pickup address"].waitForExistence(timeout: 10))
            stopMeasuring()
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.buttons["Book a pickup"].waitForExistence(timeout: 10))
        }
    }
}
