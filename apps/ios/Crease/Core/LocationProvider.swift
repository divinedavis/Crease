import CoreLocation
import MapKit
import SwiftUI

/// Where the customer is, used only to bias address suggestions.
///
/// Without this, typing "Bedford" offers a Bedford Avenue in every city in the
/// country and the right one is rarely near the top. With it, the first
/// suggestions are the streets within a few miles of where someone is standing,
/// which is almost always what they meant.
///
/// Deliberately when-in-use and never background: the app has no reason to know
/// where anyone is once they have closed it, and asking for more than that
/// invites a refusal that costs the feature entirely.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Ask only at the point it pays for itself — when the address field opens
    /// — rather than at launch, where the prompt has no visible purpose and
    /// gets denied.
    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// The area to bias suggestions toward. Falls back to the service area so
    /// search still works when location is denied — a refusal degrades the
    /// ranking, it does not break the feature.
    var searchRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate ?? .brooklyn,
            span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
        )
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in self.coordinate = latest.coordinate }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: searchRegion already falls back to the service area.
    }
}
