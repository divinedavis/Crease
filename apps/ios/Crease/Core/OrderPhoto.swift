import UIKit

/// A photo the customer attaches to an order before the bag leaves the house.
///
/// Two kinds, both for the shop: the handoff photo is the custody record ("this
/// is what was in the bag, at this time"), and a stain close-up carries its own
/// note so the counter knows what to treat and where.
struct OrderPhoto: Identifiable, Equatable {
    enum Kind: String {
        case handoff
        case stain
    }

    static let bucket = "order-photos"
    /// Mirrors the cap in migration 0049's insert policy.
    static let maxPerOrder = 12

    let id = UUID()
    let image: UIImage
    var kind: Kind
    var note: String = ""
    let takenAt: Date

    init(image: UIImage, kind: Kind, note: String = "", takenAt: Date = Date()) {
        self.image = image
        self.kind = kind
        self.note = note
        self.takenAt = takenAt
    }

    static func == (a: OrderPhoto, b: OrderPhoto) -> Bool {
        a.id == b.id && a.kind == b.kind && a.note == b.note
    }
}

extension Array where Element == OrderPhoto {
    /// The note the shop reads about these photos, alongside anything else.
    func shopNote(careNotes: [String] = [], ticket: String? = nil) -> String? {
        let handoff = filter { $0.kind == .handoff }
        return ShopNote.compose(
            stainNotes: filter { $0.kind == .stain }.map(\.note),
            careNotes: careNotes,
            ticket: ticket,
            handoffPhotoCount: handoff.count,
            handoffAt: handoff.map(\.takenAt).max()
        )
    }
}
