import XCTest
@testable import Crease

/// The rules that decide whether the customer gets a tappable number.
///
/// Two callers share them now — the shop, and the driver holding the bag — and
/// they arrive in different shapes: a shop types whatever it types into the
/// portal, while a carrier hands back an E.164 proxy line. Getting this wrong
/// in either direction is visible: a formatter that gives up shows the
/// customer `+17185550142` mid-sentence, and a dialer that does not give up
/// opens an empty keypad, which reads as the tap having failed.
final class PhoneNumberTests: XCTestCase {

    func testAnElevenDigitE164ReadsAsAPhoneNumber() {
        // What Uber Direct returns for a courier.
        XCTAssertEqual(PhoneNumber.formatted("+17185550142"), "(718) 555-0142")
    }

    func testATenDigitNumberIsFormattedToo() {
        XCTAssertEqual(PhoneNumber.formatted("7185550142"), "(718) 555-0142")
    }

    func testWhateverTheShopTypedIsAccepted() {
        // The portal's phone field is a free-text `type="tel"`.
        XCTAssertEqual(PhoneNumber.formatted("(718) 555-0142"), "(718) 555-0142")
        XCTAssertEqual(PhoneNumber.formatted("718-555-0142"), "(718) 555-0142")
        XCTAssertEqual(PhoneNumber.formatted("718.555.0142"), "(718) 555-0142")
    }

    func testSomethingUnrecognisableIsShownAsGiven() {
        // Better an odd-looking string the customer can still read out than a
        // row that silently disappears because it did not match a pattern.
        XCTAssertEqual(PhoneNumber.formatted("+44 20 7946 0958"), "+44 20 7946 0958")
    }

    func testNothingToShowWhenThereIsNoNumber() {
        XCTAssertNil(PhoneNumber.formatted(nil))
        XCTAssertNil(PhoneNumber.callURL(nil))
    }

    func testATruncatedNumberIsNotDialable() {
        // This is the case that matters: an affordance that opens an empty
        // dialer is worse than an absent one, because people keep tapping it.
        XCTAssertNil(PhoneNumber.callURL("555-0142"))
        XCTAssertNil(PhoneNumber.callURL(""))
    }

    func testTheDialedURLKeepsThePlusAndDropsEverythingElse() {
        XCTAssertEqual(PhoneNumber.callURL("+1 (718) 555-0142")?.absoluteString, "tel:+17185550142")
        XCTAssertEqual(PhoneNumber.callURL("(718) 555-0142")?.absoluteString, "tel:7185550142")
    }
}
