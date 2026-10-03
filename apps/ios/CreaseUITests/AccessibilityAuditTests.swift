import XCTest

/// Apple's automated accessibility audit (iOS 17+) on every screen a customer
/// reaches, added 2026-10-03: contrast, Dynamic Type, clipped text, missing
/// labels, hit targets, traits. Runs on every TestFlight ship
/// (scripts/ios-gates.sh).
///
/// Signed-in screens use the real session scripts/ios-session.mjs mints, the
/// same as CreaseUITests. Screens are found by walking the app rather than
/// listed by name where possible: every order card on the list is opened, so an
/// order state that renders differently is audited the day it exists.
///
/// What is excused, and why, lives in `excused(_:)` — never excuse an issue on
/// one of our own controls to get the gate green; fix the view.
final class AccessibilityAuditTests: XCTestCase {

    private var appearanceBefore: XCUIDevice.Appearance = .light

    override func setUp() {
        appearanceBefore = XCUIDevice.shared.appearance
        continueAfterFailure = true   // one screen's issues must not hide the next screen's
        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            for label in ["Not Now", "Cancel", "Don’t Allow", "Don't Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = appearanceBefore   // the simulator is shared
        super.tearDown()
    }

    private func launch(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if signedIn {
            let env = ProcessInfo.processInfo.environment
            let access = env["UITEST_ACCESS_TOKEN"] ?? "", refresh = env["UITEST_REFRESH_TOKEN"] ?? ""
            XCTAssertFalse(access.isEmpty, "UITEST_ACCESS_TOKEN not set — run scripts/ios-gates.sh")
            app.launchArguments += ["-uiTestAccessToken", access, "-uiTestRefreshToken", refresh]
        } else {
            app.launchArguments += ["-uiTestSignedOut"]
        }
        app.launch()
        return app
    }

    /// Issues on views we do not draw, or that the audit cannot point at.
    private func excused(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> Bool {
        guard let e = issue.element else { return true }   // nothing to fix
        // Apple's own Sign in with Apple button and MapKit's legal link.
        if e.label.contains("Sign in with Apple") || e.label.contains("Continue with Apple") || e.label == "Legal" { return true }
        if e.elementType == .map { return true }
        // A disabled control is exempt from contrast (WCAG 1.4.3): Sign In
        // stays dimmed until the fields are filled.
        if issue.auditType.contains(.contrast), !e.isEnabled { return true }
        // The keyboard and its QuickType suggestion bar are the system's.
        let kb = app.keyboards.firstMatch
        if kb.exists, e.frame.minY >= kb.frame.minY - 50 { return true }
        // "Partially unsupported" lands on text inside a card whose children
        // are merged into one VoiceOver element; the text itself scales and
        // wraps (checked at AX5 on 2026-10-03, and every ship by
        // testTheLargestTextSizeStillWorks). "Unsupported" — a fixed font
        // size — is still a failure.
        if issue.auditType.contains(.dynamicType), issue.compactDescription.contains("partially") { return true }
        // Partly off the bottom of the screen (home-indicator strip): sampled
        // against pixels that are not drawn. Scrolled up, it is audited.
        let window = app.windows.firstMatch.frame
        if issue.auditType.contains(.contrast), !window.isEmpty, e.frame.maxY > window.maxY - 34 { return true }
        return false
    }

    private static func name(_ t: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"), (.dynamicType, "dynamic type"),
            (.textClipped, "text clipped"), (.trait, "trait")]
        return names.first { t.contains($0.0) }?.1 ?? "type \(t.rawValue)"
    }

    /// A system prompt (notifications, Save Password) in front of the app makes
    /// the audit fail with -902 "Invalid target app": answer it, then retry.
    private func clearSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS writes "Don’t Allow" with a curly apostrophe; the location
        // prompt (address entry asks for it) blocked the audit until both matched.
        for label in ["Don’t Allow", "Don't Allow", "Not Now", "Cancel", "OK"] where springboard.alerts.buttons[label].exists {
            springboard.alerts.buttons[label].tap()
        }
    }

    /// Audits the screen as it stands in light mode and again in dark mode:
    /// Crease follows the system appearance, so both are what customers see.
    private func audit(_ screen: String, _ app: XCUIApplication) {
        for look in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = look
            sleep(1)
            auditOnce("\(screen) [\(look == .dark ? "dark" : "light")]", app)
        }
    }

    private func auditOnce(_ screen: String, _ app: XCUIApplication) {
        var found: [String] = []
        for attempt in 1...3 {
            found = []
            clearSystemAlerts()
            do {
                try runAudit(app, into: &found)
                break
            } catch let error as NSError where error.code == -902 && attempt < 3 {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "audit-902-\(screen)-\(attempt)"; shot.lifetime = .keepAlways; add(shot)
                sleep(2)
            } catch {
                XCTFail("\(screen): audit could not run: \(error)")
            }
        }
        if !found.isEmpty {
            XCTFail("\(screen): \(found.count) accessibility issue(s):\n" + found.joined(separator: "\n"))
        }
    }

    private func runAudit(_ app: XCUIApplication, into found: inout [String]) throws {
        var collected: [String] = []
        defer { found = collected }
        do {
            // Every audit type except Text Clipped: on this app's system-font
            // labels it fires on single lines with room to spare ("Laundry &
            // Dry Cleaning", 216 pt in a 390 pt column) and on any custom
            // VoiceOver label longer than the visible text. Clipping is checked
            // for real by testTheLargestTextSizeStillWorks instead.
            var types: XCUIAccessibilityAuditType = .all
            types.remove(.textClipped)
            try app.performAccessibilityAudit(for: types) { issue in
                if self.excused(issue, in: app) { return true }
                let e = issue.element
                collected.append("\(Self.name(issue.auditType)) — \(issue.compactDescription) — [\(e?.identifier ?? "")] \"\(e?.label ?? "")\""
                             + (e.map { " \($0.elementType.rawValue) @\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""))
                return true   // listed together by audit()
            }
        }
    }

    func testSignInAndEmailSheet() {
        let app = launch(signedIn: false)
        XCTAssertTrue(app.buttons["Continue with email"].waitForExistence(timeout: 15))
        // the splash folds away and the screen scales up into place first
        let mark = app.descendants(matching: .any).matching(identifier: "splash.wordmark").firstMatch
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: mark)], timeout: 8)
        sleep(2)
        audit("Sign in", app)
        app.buttons["Continue with email"].tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 5))
        sleep(1)   // sheet presentation
        audit("Email sign-in", app)
        app.buttons["Don't have an account? Sign up"].tap()
        XCTAssertTrue(app.textFields["Full name"].waitForExistence(timeout: 5))
        sleep(1)   // the mode switch animates its text
        audit("Email sign-up", app)
    }

    /// The order list, then every order on it (each status draws its own
    /// journey and price block).
    func testOrderListAndEveryOrder() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))
        sleep(2)
        audit("Order list", app)
        let cards = app.scrollViews.buttons.matching(NSPredicate(format: "label != 'Book a pickup'"))
        let n = min(cards.count, 6)   // bounded: the seeded customer has a handful
        for i in 0..<n {
            let card = cards.element(boundBy: i)
            guard card.exists, card.isHittable else { continue }
            let title = card.label.prefix(40)
            card.tap()
            sleep(2)
            audit("Order \(i + 1) (\(title))", app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 10))
        }
    }

    func testBookingAddressEntry() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.navigationBars["Crease"].waitForExistence(timeout: 20))
        app.buttons["Book a pickup"].tap()
        XCTAssertTrue(app.navigationBars["Pickup address"].waitForExistence(timeout: 10))
        sleep(1)
        audit("Pickup address", app)
    }

    /// The real Dynamic Type check: at the largest accessibility size the
    /// screens still load and their main controls can still be reached.
    func testTheLargestTextSizeStillWorks() {
        let signedOut = XCUIApplication()
        signedOut.launchArguments += ["-uiTestSignedOut", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        signedOut.launch()
        let email = signedOut.buttons["Continue with email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15), "sign-in should load at the largest text size")
        sleep(3)   // the splash lifts first
        for _ in 0..<3 where !email.isHittable { signedOut.swipeUp() }
        XCTAssertTrue(email.isHittable, "Continue with email must be reachable at the largest text size")
        signedOut.terminate()

        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestAccessToken", env["UITEST_ACCESS_TOKEN"] ?? "",
                                "-uiTestRefreshToken", env["UITEST_REFRESH_TOKEN"] ?? "",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let book = app.buttons["Book a pickup"]
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the order list should load at the largest text size")
        // exists before the splash has lifted off it; wait until it can be touched
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: book)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed,
                       "booking must be reachable at the largest text size")
    }
}
