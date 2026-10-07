import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Translates the customer's note into the language the shop's counter reads,
/// on the phone, with Apple's Translation framework (iOS 18+).
///
/// A TranslationSession can only be had from a view, so the booking asks this
/// object and the visible checkout screen hosts the session (`.hostsNoteTranslation`).
/// Whatever happens — older iOS, a language Apple does not support, a
/// declined download, a timeout — the answer is nil and the note goes as typed.
@MainActor
final class NoteTranslator: ObservableObject {
    struct Job {
        let text: String
        let target: String
        let finish: (String?) -> Void
    }

    @Published fileprivate(set) var job: Job?

    /// The shop's language when it differs from the phone's; nil otherwise.
    nonisolated static func targetLanguage(shop: String?, phone: Locale = .current) -> String? {
        guard let shop, !shop.isEmpty else { return nil }
        let shopCode = Locale.Language(identifier: shop).languageCode?.identifier
        let phoneCode = phone.language.languageCode?.identifier
        return shopCode == nil || shopCode == phoneCode ? nil : shop
    }

    func translate(_ text: String, into language: String) async -> String? {
        #if canImport(Translation)
        guard #available(iOS 18.0, *) else { return nil }
        let status = await LanguageAvailability().status(
            from: Locale.current.language,
            to: Locale.Language(identifier: language)
        )
        guard status != .unsupported else { return nil }
        return await withCheckedContinuation { continuation in
            var done = false
            let finish: (String?) -> Void = { [weak self] result in
                guard !done else { return }
                done = true
                self?.job = nil
                continuation.resume(returning: result)
            }
            job = Job(text: text, target: language, finish: finish)
            // A language download the customer ignores must not hold the booking.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                finish(nil)
            }
        }
        #else
        return nil
        #endif
    }
}

private struct HostsNoteTranslation: ViewModifier {
    @ObservedObject var translator: NoteTranslator

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.translationTask(
                translator.job.map { TranslationSession.Configuration(target: Locale.Language(identifier: $0.target)) }
            ) { session in
                guard let job = translator.job else { return }
                let out = try? await session.translate(job.text).targetText
                await MainActor.run { job.finish(out) }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Apple's translation popover (iOS 17.4+); a no-op before that.
    @ViewBuilder
    func translatable(isPresented: Binding<Bool>, text: String) -> some View {
        #if canImport(Translation)
        if #available(iOS 17.4, *) {
            translationPresentation(isPresented: isPresented, text: text)
        } else {
            self
        }
        #else
        self
        #endif
    }

    func hostsNoteTranslation(_ translator: NoteTranslator) -> some View {
        modifier(HostsNoteTranslation(translator: translator))
    }
}
