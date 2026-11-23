import CoreLocation
import Foundation

/// Where this customer put the pin last time, per street address.
///
/// Owner, 2026-11-22: "place pin at the same spot if the address was used
/// before". A geocode lands on the building's middle or the kerb in front of
/// it; the customer's own nudge (the side door, the corner by the buzzer) is
/// the better answer, so the next time the same address is picked the pin
/// opens there.
///
/// Two sources, best first: a saved address with that street and ZIP (the
/// server's copy, so it follows the customer to a new phone), then the last
/// pin confirmed on this phone. Either is only trusted near the fresh geocode:
/// four of the first six saved rows held the map's Brooklyn fallback two miles
/// from the door, and a stale point that far off is worse than no memory.
enum PinMemory {
    private static let key = "pinMemory.v1"
    private static let maxEntries = 50
    /// A pin nudged to a side door is tens of metres off the geocode, never
    /// hundreds.
    static let trustRadiusMeters: CLLocationDistance = 250

    /// "251 DeKalb Ave", "11205" and "251 dekalb ave " are the same door.
    static func addressKey(line1: String, postalCode: String) -> String {
        let street = line1
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(street)|\(postalCode.prefix(5))"
    }

    static func remember(_ address: ResolvedAddress, at point: CLLocationCoordinate2D, defaults: UserDefaults = .standard) {
        guard address.isDeliverable else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        all[addressKey(line1: address.line1, postalCode: address.postalCode)] =
            [point.latitude, point.longitude, Date().timeIntervalSince1970]
        if all.count > maxEntries {
            // Oldest out: the third number is when it was confirmed.
            let keep = all.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(maxEntries)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(all, forKey: key)
    }

    static func recalled(_ address: ResolvedAddress, defaults: UserDefaults = .standard) -> CLLocationCoordinate2D? {
        let all = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        guard let v = all[addressKey(line1: address.line1, postalCode: address.postalCode)], v.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: v[0], longitude: v[1])
    }

    /// The geocoded address, moved to where this customer pinned it before
    /// when there is a trustworthy memory of that.
    static func applied(
        to address: ResolvedAddress,
        saved: [(line1: String, postalCode: String, coordinate: CLLocationCoordinate2D?)],
        defaults: UserDefaults = .standard
    ) -> ResolvedAddress {
        let wanted = addressKey(line1: address.line1, postalCode: address.postalCode)
        let fromServer = saved
            .first { addressKey(line1: $0.line1, postalCode: $0.postalCode) == wanted }?
            .coordinate
        for candidate in [fromServer, recalled(address, defaults: defaults)] {
            guard let point = candidate, isNear(point, address.coordinate) else { continue }
            var moved = address
            moved.coordinate = point
            return moved
        }
        return address
    }

    static func isNear(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) <= trustRadiusMeters
    }
}
