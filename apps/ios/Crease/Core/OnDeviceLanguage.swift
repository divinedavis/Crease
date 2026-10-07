import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Apple Intelligence), where the phone has it.
///
/// Every feature that uses it has a working path without it: the plain-English
/// order parser falls back to OrderTextParser, and notes are sent as typed. So
/// availability only decides how good the result is, never whether the
/// feature works. Nothing here leaves the phone and nothing is billed.
///
/// OWASP LLM: the model reads only what this customer typed or said, and its
/// output is never trusted as-is — garment names must match a line on the
/// shop's own price list, counts are clamped to the steppers' ranges, and
/// notes are length-capped plain text shown back to the customer before they
/// are sent. A prompt-injected answer can at worst change the customer's own
/// draft, which they see and confirm.
enum OnDeviceLanguage {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Fill in what the rule-based parser could not: garments it did not
    /// recognise ("my good wool overcoat" -> Overcoat). Returns the parser's
    /// result unchanged when there is no model or nothing was left over.
    static func improve(_ parsed: ParsedOrder, text: String, menu: [ServiceItem]) async -> ParsedOrder {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable, !parsed.unmatched.isEmpty || parsed.quantities.isEmpty {
            let lines = menu.map { "- \($0.label) (\($0.isByWeight ? "by the pound" : "per piece"))" }.joined(separator: "\n")
            let session = LanguageModelSession(instructions: """
                You turn a customer's description of their dry cleaning or laundry into \
                lines from the shop's price list. Use only these exact line names:
                \(lines)
                If something they mention is not on the list, leave it out. Never invent lines.
                """)
            guard let answer = try? await session.respond(
                to: String(text.prefix(500)),
                generating: ModelOrder.self
            ).content else { return parsed }
            var out = parsed
            for line in answer.lines {
                guard let item = menu.first(where: { $0.label.caseInsensitiveCompare(line.name) == .orderedSame }) else { continue }
                let ceiling: Double = item.isByWeight ? 200 : 99
                let qty = min(max(line.quantity, 0), ceiling)
                guard qty > 0 else { continue }
                // The rule-based count wins where both found the line: it read
                // a number the customer actually typed.
                if out.quantities[item.id] == nil { out.quantities[item.id] = qty }
                out.service = out.service ?? ServiceKind(rawValue: item.serviceType)
            }
            out.unmatched = []
            return out
        }
        #endif
        return parsed
    }

    /// A rambling spoken instruction made into one short line a courier can
    /// read at a glance. nil when there is no model; the caller keeps the
    /// transcript as said.
    static func courierNote(from transcript: String) async -> String? {
        await rewrite(
            transcript,
            instructions: """
                Rewrite the customer's words as one short delivery instruction for a courier \
                picking up a laundry bag: buzzer, floor, door, where to meet, who to hand it to. \
                Keep every number, name and unit exactly. Under 140 characters. No greeting.
                """,
            limit: 200
        )
    }

    /// A stain description made into the note a dry cleaner's counter wants:
    /// what it is, where it is, the fabric if said, how old.
    static func stainNote(from description: String) async -> String? {
        await rewrite(
            description,
            instructions: """
                Rewrite the customer's description of a stain as a short note for a dry cleaner: \
                what the stain is, where on the garment, the fabric if mentioned, and how old if \
                mentioned. Do not add advice or anything they did not say. Under 120 characters.
                """,
            limit: 160
        )
    }

    private static func rewrite(_ text: String, instructions: String, limit: Int) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            guard let reply = try? await session.respond(to: String(trimmed.prefix(600))).content else { return nil }
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            return clean.isEmpty ? nil : String(clean.prefix(limit))
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct ModelOrder {
    @Guide(description: "Each price-list line the customer asked for, with how many (pieces) or how much (pounds).")
    var lines: [ModelOrderLine]
}

@available(iOS 26.0, *)
@Generable
struct ModelOrderLine {
    @Guide(description: "The exact line name from the shop's price list.")
    var name: String
    @Guide(description: "Number of pieces, or pounds for a by-the-pound line.")
    var quantity: Double
}
#endif
