import Foundation
import MapKit
import SwiftUI

/// Address autocomplete backed by MapKit.
///
/// `MKLocalSearchCompleter` is the right tool here: it is on-device, free, has
/// no API key to leak or bill, and returns the same suggestions Apple Maps
/// does — which is what people expect an address field to behave like.
/// Reaching for Google Places would add a key, a cost per keystroke, and a
/// second geocoder whose results disagree with the map we already draw.
@MainActor
final class AddressSearch: NSObject, ObservableObject {
    @Published var query = "" {
        didSet {
            completer.queryFragment = query
            if query.isEmpty { results = [] }
        }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var isResolving = false

    private let completer = MKLocalSearchCompleter()

    /// Bias results toward where the customer actually is. Without this a
    /// search for "Bedford Ave" offers one in every city in the country.
    init(region: MKCoordinateRegion? = nil) {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        completer.region = region ?? Self.serviceRegion
        // Crease only collects in Brooklyn, so ask MapKit for Brooklyn
        // addresses rather than for nearby ones ranked against the whole
        // country (owner, 2026-11-22: "prioritize Brooklyn addresses so they
        // show faster"). iOS 18 can make the region a requirement; on 17 the
        // ranking below does the same job after the fact.
        if #available(iOS 18.0, *) { completer.regionPriority = .required }
    }

    /// Brooklyn, centred on the partner shop on Fulton Street. Wide enough for
    /// the whole borough, so an address at the edge of the three-mile area is
    /// still found and then told honestly whether it is served.
    static let serviceRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.6834, longitude: -73.9671),
        span: MKCoordinateSpan(latitudeDelta: 0.16, longitudeDelta: 0.16)
    )

    /// Re-centre on where the customer is, but only while they are in or near
    /// Brooklyn: someone booking from their office in Midtown still wants
    /// their Brooklyn address, not the street they are standing on.
    func setRegion(_ region: MKCoordinateRegion) {
        let c = region.center, home = Self.serviceRegion.center
        let near = abs(c.latitude - home.latitude) < 0.12 && abs(c.longitude - home.longitude) < 0.12
        completer.region = near ? region : Self.serviceRegion
    }

    /// Brooklyn first, then the rest of New York, then anywhere else, keeping
    /// MapKit's order inside each group. Once there is a Brooklyn match the
    /// out-of-state ones are dropped: "251 Dekalb" in King of Prussia is never
    /// the address a Crease customer meant.
    nonisolated static func ranked<T>(_ items: [T], subtitle: (T) -> String) -> [T] {
        func group(_ item: T) -> Int {
            let s = subtitle(item).lowercased()
            if s.contains("brooklyn") { return 0 }
            if s.contains("new york") || s.contains(", ny") || s.hasPrefix("ny") { return 1 }
            return 2
        }
        let grouped = items.enumerated().sorted { a, b in
            let (ga, gb) = (group(a.element), group(b.element))
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element)
        guard grouped.contains(where: { group($0) == 0 }) else { return grouped }
        return grouped.filter { group($0) < 2 }
    }

    /// Turn a suggestion into a real coordinate and postal address.
    ///
    /// The completion itself carries only display text; a courier needs a
    /// street, city, state and ZIP, and the dispatcher needs a coordinate.
    func resolve(_ completion: MKLocalSearchCompletion) async -> ResolvedAddress? {
        isResolving = true
        defer { isResolving = false }

        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first
        else { return nil }

        let placemark = item.placemark
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")

        return ResolvedAddress(
            line1: street.isEmpty ? (placemark.name ?? completion.title) : street,
            city: placemark.locality ?? "",
            state: placemark.administrativeArea ?? "",
            postalCode: placemark.postalCode ?? "",
            coordinate: placemark.coordinate
        )
    }
}

extension AddressSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let updated = AddressSearch.ranked(completer.results) { $0.subtitle }
        Task { @MainActor in self.results = updated }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct ResolvedAddress: Equatable {
    var line1: String
    var city: String
    var state: String
    var postalCode: String
    var coordinate: CLLocationCoordinate2D

    var oneLine: String {
        [line1, city, "\(state) \(postalCode)"]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: ", ")
    }

    /// A courier cannot be sent to a partial address, so the flow refuses to
    /// advance until every field a delivery needs is actually present.
    var isDeliverable: Bool {
        !line1.isEmpty && !city.isEmpty && !state.isEmpty && postalCode.count >= 5
    }

    static func == (a: ResolvedAddress, b: ResolvedAddress) -> Bool {
        a.line1 == b.line1 && a.city == b.city && a.state == b.state
            && a.postalCode == b.postalCode
    }
}

extension CLLocationCoordinate2D {
    static let brooklyn = CLLocationCoordinate2D(latitude: 40.7178, longitude: -73.9569)
}
