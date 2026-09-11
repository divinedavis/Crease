# Crease — raw App Store marketing screenshots

Captured via `scripts/marketing-shots.sh` (XCUITest `CreaseUITests/MarketingScreenshots`),
signed in with a session minted for the seeded test customer
(`testcustomer@crease.local`, password from keychain `crease-test-password`).
No real accounts created, no real orders placed — this reuses the repo's
existing test-account session-injection path (`UITEST_ACCESS_TOKEN`/
`UITEST_REFRESH_TOKEN` launch args wired in `Session.swift`).

Simulator: `PM-shots-L` (iPhone 17 Pro Max, iOS 26.5), light appearance,
status bar frozen at 9:41/full battery/charging/4 bars/wifi, location set to
Brooklyn (40.6782, -73.9442). All five PNGs verified at exactly 1320x2868
with `sips`.

01-orders-history.png — the app's home tab: a list of the customer's orders
(Draft, Ready for delivery, Being cleaned) with status progress bars and
prices — proposed headline: "See all your orders"

02-schedule-pickup.png — the pickup-address screen with the saved Home
address offered as a one-tap shortcut — proposed headline: "Schedule
delivery in seconds"

03-choose-service.png — map pin at the pickup address, the matched partner
cleaner, and the three delivery tiers (round trip / return only / pickup
only) with prices — proposed headline: "Choose your cleaner"

04-order-total.png — the order-builder sheet: pounds of laundry via a
stepper against the shop's per-pound rate, with the estimated total —
proposed headline: "See your price upfront"

05-track-order.png — an order's status screen: the four-stage progress
track (Pickup / At cleaner / Cleaning / Return) plus order number, cleaner,
service, and address — proposed headline: "Track your delivery live"

## Notes for whoever composes the final panels
- Headlines describe delivery, not "dry cleaning" (memory flagged the old
  panels used that wording; the product is a courier/delivery service, the
  cleaning itself is done by the partner shop).
- A first capture attempt caught the iOS system location-permission sheet
  covering the address screen (the app hadn't been granted location yet in
  a fresh simulator). Fixed by pre-granting it with
  `xcrun simctl privacy <UDID> grant location com.divinedavis.crease`
  before rerunning the capture — no source or test changes needed.
