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
    let onConfirm: (ResolvedAddress, String) -> Void

    @State private var camera: MapCameraPosition
    @State private var centre: CLLocationCoordinate2D
    @State private var notes = ""
    @State private var isDragging = false

    init(address: ResolvedAddress, onConfirm: @escaping (ResolvedAddress, String) -> Void) {
        self.address = address
        self.onConfirm = onConfirm
        _centre = State(initialValue: address.coordinate)
        _camera = State(initialValue: .region(MKCoordinateRegion(
            center: address.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        )))
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
        }
        .padding(.horizontal, 16)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.accent)
                Text(address.oneLine)
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            TextField("Buzzer, floor, or where to meet you", text: $notes, axis: .vertical)
                .lineLimit(1...3)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Access notes for the driver")

            Button {
                var picked = address
                picked.coordinate = centre
                onConfirm(picked, notes)
            } label: {
                Text("Confirm pickup point")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }
}
