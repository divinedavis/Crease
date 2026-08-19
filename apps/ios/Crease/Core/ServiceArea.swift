import Foundation

/// Where Crease actually collects from.
///
/// Three miles from Fulton Cleaners at 909 Fulton Street — the courier band the
/// whole price sheet is built on, because Uber Direct is essentially flat under
/// three miles in Brooklyn and steps up past it.
///
/// The neighbourhood list is measured rather than assumed: every shop in the
/// Brooklyn canvass carries coordinates, and thirty NYC neighbourhoods have at
/// least one inside the band. Naming only Clinton Hill and Fort Greene sold the
/// area far shorter than it is — Downtown Brooklyn is 0.7 miles out, Park Slope
/// 0.5, Williamsburg 1.9. Kept in step with apps/web/lib/neighborhoods.ts; if
/// the shop moves or a second one signs, both change.
enum ServiceArea {
    static let radiusMiles = 3
    static let partner = "Fulton Cleaners"
    static let partnerAddress = "909 Fulton Street"

    /// Comfortably inside, in the order somebody would recognise them.
    static let core = [
        "Clinton Hill", "Fort Greene", "Prospect Heights", "Bedford-Stuyvesant",
        "Park Slope", "Downtown Brooklyn", "DUMBO", "Boerum Hill", "Crown Heights",
        "Gowanus", "Carroll Gardens", "Cobble Hill", "Red Hook", "Brooklyn Heights",
        "Prospect Lefferts Gardens", "South Williamsburg", "Windsor Terrace", "South Slope",
    ]

    /// Reached in part — the far end of each is outside the band, which is why
    /// the address itself is the answer and the neighbourhood never is.
    static let edge = [
        "Williamsburg", "East Williamsburg", "Bushwick", "Flatbush", "Ditmas Park",
        "Kensington", "East Flatbush", "Ocean Hill", "Greenpoint", "Borough Park", "Sunset Park",
    ]

    /// One paragraph for a screen that has room for one paragraph.
    static var blurb: String {
        let lead = core.prefix(6).joined(separator: ", ")
        let more = core.count + edge.count - 6
        return "Within \(radiusMiles) miles of \(partner), \(partnerAddress) — \(lead) and \(more) more neighborhoods. Type your address and we'll tell you either way."
    }
}
