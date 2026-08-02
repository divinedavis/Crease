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
        if let region { completer.region = region }
    }

    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
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
        let updated = completer.results
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
