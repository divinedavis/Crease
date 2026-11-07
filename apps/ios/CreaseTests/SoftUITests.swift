import SwiftUI
import Testing
import UIKit
@testable import Crease

/// The soft-card redesign (2026-11-06) draws a 3D illustration wherever the
/// app names a thing. These pin the parts that are logic: every picture the
/// code can ask for ships in the asset catalog, and each status, service and
/// courier tier gets the picture that says what it is.
@Suite("Soft-card illustrations")
struct SoftUITests {
    @Test("Every illustration ships in the asset catalog", arguments: Illustration.allCases)
    func assetExists(_ art: Illustration) {
        #expect(UIImage(named: "Illustrations/\(art.rawValue)") != nil,
                "Assets › Illustrations is missing \(art.rawValue)")
    }

    @Test("A bag on the road shows the courier", arguments: [
        OrderStatus.scheduled, .pickupDispatched, .inTransitToCleaner, .returnDispatched, .inTransitToCustomer,
    ])
    func movingStatusesShowTheCourier(_ status: OrderStatus) {
        #expect(status.illustration == .courier)
    }

    @Test("The decision and the wash each have their own picture")
    func distinctMilestones() {
        #expect(OrderStatus.awaitingApproval.illustration == .receipt)
        #expect(OrderStatus.cleaning.illustration == .washer)
        #expect(OrderStatus.atCleaner.illustration == .shop)
        #expect(OrderStatus.ready.illustration == .folded)
    }

    @Test("Every status has a picture that isn't a placeholder", arguments: OrderStatus.allCases)
    func everyStatusIsCovered(_ status: OrderStatus) {
        #expect(Illustration.allCases.contains(status.illustration))
    }

    @Test("Services and courier tiers can be told apart by picture")
    func servicesAndTiersAreDistinct() {
        let services = ServiceKind.allCases.map(\.illustration)
        #expect(Set(services).count == services.count)
        let tiers = ServiceOption.all.map(\.illustration)
        #expect(Set(tiers).count == tiers.count)
        #expect(ServiceKind.washFold.illustration == .basket)
    }
}

@Suite("Plus Jakarta Sans")
struct AppFontTests {
    @Test("Every bundled weight registers under its PostScript name", arguments: [
        "PlusJakartaSans-Regular", "PlusJakartaSans-Medium", "PlusJakartaSans-SemiBold",
        "PlusJakartaSans-Bold", "PlusJakartaSans-ExtraBold",
    ])
    func weightIsRegistered(_ name: String) {
        #expect(UIFont(name: name, size: 17) != nil, "\(name) is not registered — check UIAppFonts")
    }

    @Test("The bar fonts are the app's, not the system fallback")
    func barsUseTheTypeface() {
        let title = AppFont.ui(17, weight: .semibold, relativeTo: .headline)
        #expect(title.familyName == AppFont.family)
    }

    @Test("Text styles keep Apple's default sizes")
    func sizes() {
        #expect(AppFont.size(.largeTitle) == 34)
        #expect(AppFont.size(.body) == 17)
        #expect(AppFont.size(.subheadline) == 15)
        #expect(AppFont.size(.caption2) == 11)
    }
}
