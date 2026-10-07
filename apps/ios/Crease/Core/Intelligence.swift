import Foundation

// The decisions behind the on-device intelligence features, kept free of
// Vision, Speech and Foundation Models so each can be tested with plain values.
// The frameworks produce labels, text and transcripts; everything that turns
// those into something that touches an order lives here.

// MARK: - Snap to itemize

/// Turns what Vision's built-in classifier saw in a photo into lines on this
/// shop's own price list.
///
/// The classifier names kinds of things, not counts, and its clothing
/// vocabulary is narrow (it knows "suit", "jeans" and "gown" but has no plain
/// "shirt" or "pants"). So this only ever suggests which lines to open; the
/// customer confirms how many. A label that matches nothing on the shop's
/// list is dropped rather than guessed at.
enum GarmentMatcher {
    /// Vision identifier -> words that appear in a shop's line labels or codes.
    static let keywords: [String: [String]] = [
        "suit": ["suit"],
        "tuxedo": ["suit", "tux"],
        "jacket": ["jacket", "blazer", "coat"],
        "lab_coat": ["coat"],
        "jeans": ["pants", "slacks", "jeans", "trouser"],
        "gown": ["dress", "gown"],
        "wedding_dress": ["gown", "dress"],
        "necktie": ["tie"],
        "bowtie": ["tie"],
        "scarf": ["scarf"],
        "bedding": ["comforter", "bedding", "duvet", "blanket"],
        "pillow": ["comforter", "bedding", "pillow"],
        "curtain": ["curtain", "drape"],
        "bathrobe": ["robe"],
    ]

    /// Labels that only say "there are clothes here": no garment to name,
    /// but enough to point a laundry bag at wash & fold.
    static let genericLaundry: Set<String> = ["clothing", "hoodie", "sock", "swimsuit"]

    static let minimumConfidence: Float = 0.25

    static func suggestions(
        labels: [(identifier: String, confidence: Float)],
        menu: [ServiceItem]
    ) -> [ServiceItem] {
        var picked: [ServiceItem] = []
        let seen = labels.filter { $0.confidence >= minimumConfidence }
        for label in seen.sorted(by: { $0.confidence > $1.confidence }) {
            guard let words = keywords[label.identifier] else { continue }
            if let item = bestLine(for: words, in: menu), !picked.contains(item) {
                picked.append(item)
            }
        }
        // Clothes with no nameable garment: the shop's weighed laundry line.
        if picked.isEmpty, seen.contains(where: { genericLaundry.contains($0.identifier) }),
           let laundry = menu.first(where: { $0.isByWeight }) {
            picked.append(laundry)
        }
        return picked
    }

    /// The first word that matches any line wins, so "coat" never beats a
    /// shop's own "jacket" line for a jacket.
    private static func bestLine(for words: [String], in menu: [ServiceItem]) -> ServiceItem? {
        for word in words {
            if let hit = menu.first(where: {
                $0.label.lowercased().contains(word) || $0.code.lowercased().contains(word)
            }) { return hit }
        }
        return nil
    }
}

// MARK: - Care labels

/// What a garment's care label says about where it belongs.
///
/// Live Text reads the words on a label, not the pictograms, so this works on
/// labels that spell it out ("DRY CLEAN ONLY", "MACHINE WASH COLD") and says
/// so when it finds nothing it can act on rather than guessing from symbols.
enum CareAdvice: Equatable {
    case dryClean
    case washable
    case unknown

    var service: ServiceKind? {
        switch self {
        case .dryClean: return .dryClean
        case .washable: return .washFold
        case .unknown: return nil
        }
    }

    var message: String {
        switch self {
        case .dryClean: return "This label says dry clean. It goes in Dry cleaning."
        case .washable: return "This label says it's washable. Wash & fold is fine."
        case .unknown: return "Couldn't find care words on that label. Try closer, or check the symbols yourself."
        }
    }

    static func read(_ lines: [String]) -> CareAdvice {
        let text = lines.joined(separator: " ").lowercased()
            .replacingOccurrences(of: "-", with: " ")
        // Negatives first: "do not dry clean" contains "dry clean".
        let noDryClean = ["do not dry clean", "dont dry clean", "don't dry clean", "no dry clean"]
        let noWash = ["do not wash", "dont wash", "don't wash", "no wash", "not washable"]
        if noDryClean.contains(where: text.contains) { return .washable }
        if noWash.contains(where: text.contains) { return .dryClean }
        let dry = ["dry clean", "dryclean", "professional clean", "nettoyage a sec",
                   "nettoyage à sec", "limpiar en seco", "lavado en seco", "chemische reinigung"]
        let wash = ["machine wash", "hand wash", "wash cold", "wash warm", "gentle cycle",
                    "lavable", "lavar a maquina", "lavar a máquina", "washable", "tumble dry"]
        let saysDry = dry.contains(where: text.contains)
        let saysWash = wash.contains(where: text.contains)
        if saysDry && !saysWash { return .dryClean }
        if saysWash && !saysDry { return .washable }
        // "Dry clean or hand wash": washable, but a shop would rather clean it.
        if saysDry && saysWash { return text.contains("only") ? .dryClean : .washable }
        return .unknown
    }
}

// MARK: - Shop tickets

/// The claim ticket a shop hands over at the counter, read off a photo.
///
/// For "Return only" orders the clothes are already at the shop, and the
/// ticket is how the counter finds them. Reading it saves typing a number off
/// a crumpled slip and, when the shop's name or phone is printed on it, picks
/// the right shop too.
struct TicketReading: Equatable {
    var number: String?
    var shopId: UUID?
}

enum TicketReader {
    static func read(_ lines: [String], shops: [Cleaner]) -> TicketReading {
        TicketReading(number: number(in: lines), shopId: shop(in: lines, shops: shops)?.id)
    }

    /// A labelled number first ("Ticket 4471", "No. A-208", "#58213"), then
    /// the longest standalone run of 3-8 digits that is not a phone number,
    /// date or price.
    static func number(in lines: [String]) -> String? {
        let labelled = try! NSRegularExpression(
            pattern: #"(?i)\b(?:ticket|tkt|claim|order|invoice|no\.?|number)\s*[:#]?\s*([A-Z]?-?\d{3,8})\b|#\s*([A-Z]?-?\d{3,8})\b"#
        )
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let m = labelled.firstMatch(in: line, range: range) {
                for group in 1...2 {
                    let r = m.range(at: group)
                    if r.location != NSNotFound, let swiftRange = Range(r, in: line) {
                        return String(line[swiftRange]).uppercased()
                    }
                }
            }
        }
        let bare = try! NSRegularExpression(pattern: #"(?<![\d$.,/:-])\d{3,8}(?![\d.,/:%-])"#)
        let candidates = lines
            .filter { !looksLikePhoneOrDate($0) }
            .flatMap { line -> [String] in
                bare.matches(in: line, range: NSRange(line.startIndex..., in: line))
                    .compactMap { Range($0.range, in: line).map { String(line[$0]) } }
            }
        return candidates.max { $0.count < $1.count }
    }

    private static func looksLikePhoneOrDate(_ line: String) -> Bool {
        let digits = line.filter(\.isNumber)
        if digits.count >= 10 { return true }
        return line.range(of: #"\d{1,2}[/.-]\d{1,2}([/.-]\d{2,4})?"#, options: .regularExpression) != nil
            || line.range(of: #"\$\s?\d"#, options: .regularExpression) != nil
    }

    /// A shop whose name (every word of it longer than two letters) or last
    /// seven phone digits appear on the ticket.
    static func shop(in lines: [String], shops: [Cleaner]) -> Cleaner? {
        let text = lines.joined(separator: " ").lowercased()
        let digits = text.filter(\.isNumber)
        return shops.first { shop in
            if let phone = shop.phone?.filter(\.isNumber), phone.count >= 7,
               digits.contains(phone.suffix(7)) { return true }
            let words = shop.name.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
            let distinctive = words.filter { !["cleaners", "cleaner", "laundry", "laundromat", "the"].contains($0) }
            return !distinctive.isEmpty && distinctive.allSatisfy { text.contains($0) }
        }
    }
}

// MARK: - Book in plain English

/// What a sentence like "2 suits and a comforter, pick up tomorrow at 9" asks
/// for, resolved against this shop's price list.
struct ParsedOrder: Equatable {
    var quantities: [UUID: Double] = [:]
    var service: ServiceKind?
    var pickupAt: Date?
    var unmatched: [String] = []

    var isEmpty: Bool { quantities.isEmpty && pickupAt == nil }
}

enum OrderTextParser {
    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "a couple": 2, "couple": 2, "a few": 3, "few": 3, "dozen": 12,
    ]

    /// Synonyms customers use -> words in shop line labels.
    private static let synonyms: [String: String] = [
        "shirts": "shirt", "blouses": "shirt", "blouse": "shirt", "tops": "shirt",
        "pants": "pants", "pant": "pants", "slacks": "pants", "trousers": "pants", "jeans": "pants",
        "suits": "suit", "dresses": "dress", "gowns": "dress", "coats": "coat",
        "overcoats": "coat", "jackets": "coat", "jacket": "coat", "blazers": "coat",
        "comforters": "comforter", "duvet": "comforter", "duvets": "comforter",
        "blankets": "comforter", "blanket": "comforter", "quilt": "comforter",
        "ties": "tie", "sweaters": "sweater", "skirts": "skirt",
        "pounds": "lb", "pound": "lb", "lbs": "lb", "lb": "lb",
    ]

    /// Parse without any model: counts, garments, pounds and a pickup time.
    /// Good enough on every device; the on-device language model, where there
    /// is one, fills in what this misses (see OnDeviceLanguage).
    static func parse(_ text: String, menu: [ServiceItem], now: Date = Date()) -> ParsedOrder {
        var out = ParsedOrder()
        let lower = text.lowercased()
        let pattern = try! NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?|a couple|couple|a few|few|dozen|an|a|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(?:of\s+)?(?:my\s+)?([a-z]+)(?:\s+([a-z]+))?"#
        )
        for m in pattern.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let countRange = Range(m.range(at: 1), in: lower),
                  let wordRange = Range(m.range(at: 2), in: lower) else { continue }
            let countText = String(lower[countRange])
            guard let count = Double(countText) ?? numberWords[countText], count > 0 else { continue }
            var word = String(lower[wordRange])
            // "2 dress shirts": the noun is the second word.
            if let second = Range(m.range(at: 3), in: lower).map({ String(lower[$0]) }),
               synonyms[second] != nil || menu.contains(where: { $0.label.lowercased().contains(second) }) {
                word = second
            }
            let key = synonyms[word] ?? word
            if key == "lb" {
                if let laundry = menu.first(where: { $0.isByWeight }) {
                    out.quantities[laundry.id] = min(count, 200)
                    out.service = ServiceKind(rawValue: laundry.serviceType)
                }
                continue
            }
            if let item = menu.first(where: {
                !$0.isByWeight && ($0.label.lowercased().contains(key) || $0.code.lowercased().contains(key))
            }) {
                out.quantities[item.id, default: 0] += min(count, 99)
                out.service = out.service ?? ServiceKind(rawValue: item.serviceType)
            } else if !["am", "pm", "at", "hour", "hours", "minutes", "min", "day", "days"].contains(word) {
                out.unmatched.append(word)
            }
        }
        // "laundry" / "wash and fold" with no weight: open the weighed line at
        // its floor so the customer sees the real starting price.
        if out.quantities.isEmpty,
           lower.contains("laundry") || lower.contains("wash and fold") || lower.contains("wash & fold"),
           let laundry = menu.first(where: { $0.isByWeight }) {
            out.quantities[laundry.id] = ServicePricing.startingUnits(laundry)
            out.service = .washFold
        }
        out.pickupAt = pickupDate(in: text, now: now)
        return out
    }

    /// A time the customer named, only if it is in the future and inside the
    /// week the scheduler offers.
    static func pickupDate(in text: String, now: Date = Date()) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        guard let date = match?.date, date > now, date < now.addingTimeInterval(7 * 86400) else { return nil }
        return date
    }
}

// MARK: - Your usual

/// The order a customer keeps placing, worked out on the phone from their own
/// history. Nothing about it leaves the device.
struct UsualOrder: Equatable {
    let cleanerId: UUID
    let cleanerName: String
    let address: Address
    /// Line label -> quantity, as last booked at this shop.
    let lines: [String: Double]
    /// 1 = Sunday ... 7 = Saturday, only when one day clearly dominates.
    let weekday: Int?
    let timesBooked: Int

    var summary: String {
        let parts = lines.sorted { $0.key < $1.key }.map { label, qty in
            label.lowercased().contains("wash") && qty >= 5
                ? "\(qty == qty.rounded() ? String(Int(qty)) : String(format: "%.1f", qty)) lb \(label.lowercased())"
                : "\(Int(qty)) × \(label.lowercased())"
        }
        return parts.joined(separator: ", ")
    }

    var dayText: String? {
        guard let weekday else { return nil }
        return Calendar.current.weekdaySymbols[weekday - 1] + "s"
    }

    /// Orders that were actually paid for and not called off.
    private static let counted: Set<OrderStatus> = Set(OrderStatus.allCases).subtracting([.draft, .cancelled, .failed])

    /// Needs two real orders at the same shop before it calls anything usual.
    static func from(_ orders: [Order], calendar: Calendar = .current) -> UsualOrder? {
        let real = orders.filter { counted.contains($0.status) && $0.cleaner != nil && $0.address != nil }
        guard real.count >= 2 else { return nil }
        let byShop = Dictionary(grouping: real) { $0.cleaner!.id }
        guard let (shopId, atShop) = byShop.max(by: { $0.value.count < $1.value.count }),
              atShop.count >= 2,
              let latest = atShop.max(by: { $0.createdAt < $1.createdAt }),
              let items = latest.orderItems, !items.isEmpty else { return nil }
        var lines: [String: Double] = [:]
        for item in items { lines[item.label, default: 0] += Double(item.quantity) }
        let days = atShop.map { calendar.component(.weekday, from: $0.pickupWindowStart ?? $0.createdAt) }
        let counts = Dictionary(grouping: days, by: { $0 }).mapValues(\.count)
        let top = counts.max { $0.value < $1.value }
        let weekday = (top.map { Double($0.value) / Double(days.count) } ?? 0) >= 0.5 && atShop.count >= 3 ? top?.key : nil
        return UsualOrder(
            cleanerId: shopId,
            cleanerName: latest.cleaner!.name,
            address: latest.address!,
            lines: lines,
            weekday: weekday,
            timesBooked: atShop.count
        )
    }

    /// The usual's lines on a shop's current price list. Lines the shop no
    /// longer sells are dropped rather than booked at a stale price.
    func quantities(on menu: [ServiceItem]) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for (label, qty) in lines {
            if let item = menu.first(where: { $0.label == label }) { out[item.id] = qty }
        }
        return out
    }
}

// MARK: - The note the shop reads

/// What the customer tells the shop, in one note on the order: stain notes,
/// care-label findings, the claim ticket and the handoff photo count. Kept
/// short because it is read at a counter, often off a phone.
enum ShopNote {
    static func compose(
        stainNotes: [String],
        careNotes: [String] = [],
        ticket: String? = nil,
        handoffPhotoCount: Int = 0,
        handoffAt: Date? = nil
    ) -> String? {
        var parts: [String] = []
        if let ticket, !ticket.isEmpty { parts.append("Ticket #\(ticket)") }
        for note in stainNotes.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !note.isEmpty {
            parts.append("Stain: \(note)")
        }
        for note in careNotes where !note.isEmpty { parts.append(note) }
        if handoffPhotoCount > 0 {
            let when = handoffAt.map { " at " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            parts.append("\(handoffPhotoCount) handoff photo\(handoffPhotoCount == 1 ? "" : "s") taken\(when)")
        }
        let note = parts.joined(separator: "\n")
        // orders.customer_notes is read at the counter; keep it a note, not an essay.
        return note.isEmpty ? nil : String(note.prefix(1000))
    }

    /// The original and the shop-language version together, so nothing is lost
    /// if the translation is off.
    static func withTranslation(_ original: String, translated: String?) -> String {
        guard let translated, !translated.isEmpty, translated != original else { return original }
        return String("\(translated)\n\n— Original —\n\(original)".prefix(2000))
    }
}
