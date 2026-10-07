@preconcurrency import AVFoundation
import Foundation
import Speech

/// Speak an instruction instead of typing it, transcribed on the phone by
/// iOS 26's SpeechAnalyzer. Audio never leaves the device and nothing is kept
/// once the words are on screen.
///
/// iOS 26 only: on anything older `isSupported` is false and the microphone
/// button is simply not shown — the keyboard's own dictation still works.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var isPreparing = false
    @Published var problem: String?

    private var stopper: (() async -> Void)?
    private var reader: Task<Void, Never>?

    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    func start() async {
        guard #available(iOS 26.0, *), !isListening, !isPreparing else { return }
        problem = nil
        transcript = ""
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Microphone access is off. Turn it on in Settings to speak your note."
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                problem = "Speaking notes isn't available in your language yet."
                return
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            // The model for this language downloads once, from Apple, on first use.
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                problem = "Couldn't start listening."
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()

            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let mic = engine.inputNode
            let micFormat = mic.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: micFormat, to: format) else {
                problem = "Couldn't start listening."
                return
            }
            mic.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
                guard let converted = Self.convert(buffer, with: converter, to: format) else { return }
                feed.yield(AnalyzerInput(buffer: converted))
            }
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: inputs)
            isListening = true

            reader = Task { [weak self] in
                var settled = ""
                do {
                    for try await result in transcriber.results {
                        let words = String(result.text.characters)
                        if result.isFinal {
                            settled += words
                            self?.transcript = settled.trimmingCharacters(in: .whitespaces)
                        } else {
                            self?.transcript = (settled + words).trimmingCharacters(in: .whitespaces)
                        }
                    }
                } catch {}
            }
            stopper = {
                mic.removeTap(onBus: 0)
                engine.stop()
                feed.finish()
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            problem = "Couldn't start listening."
        }
    }

    /// Stop, let the last words settle, and return everything heard.
    @discardableResult
    func stop() async -> String {
        await stopper?()
        stopper = nil
        await reader?.value
        reader = nil
        isListening = false
        return transcript
    }

    /// The mic's native format to the analyzer's, one buffer at a time.
    nonisolated private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
