import XCTest

extension XCUIApplication {
    /// iOS 26's floating tab bar ignores element taps; a coordinate tap lands,
    /// and `isSelected` is the only trustworthy confirmation.
    func selectTab(_ name: String) -> Bool {
        let tab = tabBars.buttons[name]
        guard tab.waitForExistence(timeout: 10) else { return false }
        for attempt in 0..<3 {
            if tab.isSelected { return true }
            if attempt == 0 { tab.tap() } else { tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab)
            if XCTWaiter().wait(for: [selected], timeout: 3) == .completed { return true }
        }
        return false
    }

    /// Orders are listed on the Activity tab only (Home dropped them,
    /// 2026-10-10), so every test that opens an order starts here.
    func openActivity(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(selectTab("Activity"), "the Activity tab did not open", file: file, line: line)
        XCTAssertTrue(navigationBars["Activity"].waitForExistence(timeout: 10), file: file, line: line)
    }
}
