import CoreLocation
import MapKit
import Testing
@testable import Crease

/// The booking map frames the whole trip into the strip left open above the
/// options sheet (owner, 2026-11-23: the shop was hidden under the sheet and
/// the door sat at its edge).
struct RouteFramingTests {
    private let size = CGSize(width: 402, height: 874)
    /// Below a 120 pt address bar, above a sheet that starts at 380 pt.
    private let open = CGRect(x: 0, y: 120, width: 402, height: 260)
    private let door = CLLocationCoordinate2D(latitude: 40.6897, longitude: -73.9733)   // DeKalb Ave
    private let shop = CLLocationCoordinate2D(latitude: 40.6861, longitude: -73.9745)   // Fulton St

    /// Where a coordinate lands on screen when `rect` fills the map view.
    private func screen(_ c: CLLocationCoordinate2D, in rect: MKMapRect) -> CGPoint {
        let k = rect.size.width / size.width
        let p = MKMapPoint(c)
        return CGPoint(x: (p.x - rect.origin.x) / k, y: (p.y - rect.origin.y) / k)
    }

    @Test func bothEndsLandInsideTheOpenStripWithRoomToSpare() throws {
        let rect = try #require(RouteFraming.mapRect(points: [door, shop], mapSize: size, visible: open))
        let pad = RouteFraming.padding
        for c in [door, shop] {
            let p = screen(c, in: rect)
            #expect(p.x >= open.minX + pad.leading - 0.5 && p.x <= open.maxX - pad.trailing + 0.5)
            #expect(p.y >= open.minY + pad.top - 0.5 && p.y <= open.maxY - pad.bottom + 0.5)
        }
    }

    @Test func aRouteThatBowsOutIsFramedWhole() throws {
        let detour = CLLocationCoordinate2D(latitude: 40.6880, longitude: -73.9650)   // well east of both ends
        let rect = try #require(RouteFraming.mapRect(points: [door, detour, shop], mapSize: size, visible: open))
        let p = screen(detour, in: rect)
        #expect(p.x <= open.maxX - RouteFraming.padding.trailing + 0.5)
    }

    @Test func theRectHasTheMapsShapeSoMapKitShowsItExactly() throws {
        let rect = try #require(RouteFraming.mapRect(points: [door, shop], mapSize: size, visible: open))
        #expect(abs(rect.size.width / rect.size.height - size.width / size.height) < 1e-9)
    }

    @Test func nearbyEndsStillShowTheStreetsAround() throws {
        let rect = try #require(RouteFraming.mapRect(points: [door, door], mapSize: size, visible: open))
        let metersAcross = rect.size.width / MKMapPointsPerMeterAtLatitude(door.latitude)
        #expect(metersAcross >= RouteFraming.minimumMeters)
    }

    @Test func noFrameUntilTheScreenIsMeasured() {
        #expect(RouteFraming.mapRect(points: [door, shop], mapSize: .zero, visible: open) == nil)
        #expect(RouteFraming.mapRect(points: [door, shop], mapSize: size, visible: CGRect(x: 0, y: 0, width: 402, height: 90)) == nil)
    }
}
