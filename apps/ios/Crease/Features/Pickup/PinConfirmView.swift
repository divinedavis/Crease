import MapKit
import SwiftUI

/// Drop the pin exactly where the courier should stand.
///
/// Geocoded addresses land on the centroid of a building, which for a corner
/// shop or a large block can be the wrong door entirely. Letting the customer
/// nudge the pin is the difference between a courier arriving and a courier
/// calling — and the map moves under a fixed pin rather than the pin moving on
/// the map, which is the interaction people already know.
struct PinConfirmView: View {
    @Environment(\.dismiss) private var dismiss

    let address: ResolvedAddress
    /// Open on where the customer is standing rather than on the address.
    ///
    /// Edit Pin at checkout is "send the driver to me", and a saved address can
    /// carry a point nowhere near its door — four of the first six saved rows
    /// held the map's Brooklyn fallback, two miles from 251 DeKalb. A typed
    /// address keeps opening on itself: whoever searched for it may be booking
    /// a pickup somewhere they are not.
    let startsAtCurrentLocation: Bool
    let onConfirm: (ResolvedAddress, String) -> Void

    @StateObject private var location = LocationProvider()
    @State private var camera: MapCameraPosition
    @State private var centre: CLLocationCoordinate2D
    /// The street address under the pin, so what the courier is told always
    /// matches where the pin is. Moving the pin used to change only the
    /// coordinate and leave the old street on the order.
    @State private var underPin: ResolvedAddress
    @State private var isGeocoding = false
    @State private var geocoder = CLGeocoder()
    @State private var movedToCurrentLocation = false
    @State private var notes = ""
    @State private var isDragging = false

    init(
        address: ResolvedAddress,
        startsAtCurrentLocation: Bool = false,
        onConfirm: @escaping (ResolvedAddress, String) -> Void
    ) {
        self.address = address
        self.startsAtCurrentLocation = startsAtCurrentLocation
        self.onConfirm = onConfirm
        // Where the customer is, from the start, when the phone already knows:
        // opening on the saved address and jumping a second later read as the
        // map starting "some random place".
        let start = startsAtCurrentLocation ? (LocationProvider.lastKnown ?? address.coordinate) : address.coordinate
        _centre = State(initialValue: start)
        _underPin = State(initialValue: address)
        _camera = State(initialValue: Self.region(start))
        _movedToCurrentLocation = State(initialValue: startsAtCurrentLocation && LocationProvider.lastKnown != nil)
    }

    /// The pin's point once the map stops moving; nil mid-drag.
    private var settledPoint: PinPoint? { isDragging ? nil : PinPoint(centre) }

    private static func region(_ centre: CLLocationCoordinate2D) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: centre,
            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { _ in
                Map(position: $camera)
                    .mapStyle(.standard(pointsOfInterest: .including([.cafe, .restaurant])))
                    .onMapCameraChange(frequency: .continuous) { context in
                        centre = context.camera.centerCoordinate
                        if !isDragging { withAnimation(.easeOut(duration: 0.15)) { isDragging = true } }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        centre = context.camera.centerCoordinate
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isDragging = false }
                    }
                    .ignoresSafeArea()
            }
            // Geocode only once the map settles, keyed on the point so a new
            // drag cancels the lookup for the old one. Apple throttles
            // reverse geocoding; one call per settled pin stays well inside it.
            .task(id: settledPoint, priority: .userInitiated) {
                guard let settledPoint else { return }
                // Where the screen opened is the address it was handed; a
                // geocode of that same point can come back a door or two off
                // ("3 Hanson Pl" for "1 Hanson Pl") and rewrite a typed street.
                if settledPoint == PinPoint(address.coordinate) {
                    underPin = address
                    return
                }
                await lookUpAddress(at: centre)
            }

            pin
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

            header
        }
        .safeAreaInset(edge: .bottom) { sheet }
    }

    private var pin: some View {
        VStack(spacing: 0) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Theme.accent, .white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                // Lifts while the map moves, so the pin reads as hovering over
                // the map rather than stuck to it.
                .offset(y: isDragging ? -10 : 0)
            Rectangle()
                .fill(.black.opacity(0.25))
                .frame(width: 3, height: isDragging ? 14 : 6)
                .blur(radius: 1)
        }
        // The pin marks the point at the centre of the map, and the map centre
        // is above the sheet, not the screen.
        .offset(y: -60)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Back")
            Spacer()
            if location.coordinate != nil {
                Button { recentre() } label: {
                    Image(systemName: "location.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Move pin to my location")
            }
        }
        .padding(.horizontal, 16)
        .onAppear { location.requestIfNeeded() }
        // The first fix lands a beat after the sheet opens. Jump to it once —
        // only once, so a later fix never yanks the map out from under a
        // customer already dragging it to their door.
        .onChange(of: location.coordinate.map(PinPoint.init)) { _, _ in
            guard startsAtCurrentLocation, !movedToCurrentLocation else { return }
            movedToCurrentLocation = true
            recentre()
        }
    }

    private func recentre() {
        guard let here = location.coordinate else { return }
        withAnimation { camera = Self.region(here) }
        centre = here
    }

    private func lookUpAddress(at point: CLLocationCoordinate2D) async {
        isGeocoding = true
        defer { isGeocoding = false }
        // One geocoder for the screen; a new drag cancels the lookup in flight
        // rather than leaving it to finish for a point nobody wants any more.
        geocoder.cancelGeocode()
        let placemarks = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: point.latitude, longitude: point.longitude)
        )
        guard !Task.isCancelled else { return }
        underPin = ResolvedAddress.underPin(placemarks?.first, at: point, fallback: address)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            Text("Set your pickup point")
                .font(.title3.weight(.semibold))
            Text("Move the map so the pin sits where the driver should meet you.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            // No street address on this screen: the pin is the answer. The
            // street under it is still looked up quietly, because Uber Direct
            // needs an address string with every booking and geocodes the
            // drop-off address itself (see underPin).
            TextField("Buzzer, floor, or where to meet you", text: $notes, axis: .vertical)
                .lineLimit(1...3)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Access notes for the driver")

            Button {
                var picked = underPin
                picked.coordinate = centre
                onConfirm(picked, notes)
            } label: {
                Text("Confirm pickup point")
                    .frame(maxWidth: .infinity)
            }
            // Never confirm a street that belongs to where the pin used to be.
            .disabled(isDragging || isGeocoding || !underPin.isDeliverable)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentFill)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }
}

/// A coordinate that can key `.task(id:)` and `.onChange`. Rounded to ~1 m so
/// float noise from the map's own camera updates does not restart a lookup.
struct PinPoint: Equatable {
    let lat: Int
    let lng: Int
    init(_ c: CLLocationCoordinate2D) {
        lat = Int((c.latitude * 100_000).rounded())
        lng = Int((c.longitude * 100_000).rounded())
    }
}

extension ResolvedAddress {
    /// The street a reverse geocode found under the pin.
    ///
    /// Falls back to the address the screen opened with when the lookup gives
    /// nothing usable — offline, throttled, or a pin dropped in a park — so the
    /// customer can still confirm the point by hand rather than being stuck.
    static func underPin(
        _ placemark: CLPlacemark?,
        at point: CLLocationCoordinate2D,
        fallback: ResolvedAddress
    ) -> ResolvedAddress {
        guard let placemark, let street = placemark.thoroughfare else {
            var kept = fallback
            kept.coordinate = point
            return kept
        }
        let line1 = [placemark.subThoroughfare, street].compactMap { $0 }.joined(separator: " ")
        let found = ResolvedAddress(
            line1: line1,
            city: placemark.locality ?? fallback.city,
            state: placemark.administrativeArea ?? fallback.state,
            postalCode: placemark.postalCode ?? fallback.postalCode,
            coordinate: point
        )
        if found.isDeliverable { return found }
        var kept = fallback
        kept.coordinate = point
        return kept
    }
}
