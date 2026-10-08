import UIKit
import Vision

/// Apple's on-device Vision models, run off the main thread.
///
/// Both requests run on the Neural Engine where the phone has one and never
/// send an image anywhere. Each call does its work on a detached task at
/// user-initiated priority so a large camera frame never stalls the sheet
/// that asked for it.
enum OnDeviceVision {
    /// The longest edge an image is scaled to before analysis. Vision works on
    /// a few hundred pixels internally; handing it a 48 MP frame only costs
    /// memory and time.
    static let analysisEdge: CGFloat = 1600

    /// Kinds of things in the photo, most confident first.
    static func classify(_ image: UIImage) async -> [(identifier: String, confidence: Float)] {
        await Perf.measure("Vision classify") { await classifyNow(image) }
    }

    private static func classifyNow(_ image: UIImage) async -> [(identifier: String, confidence: Float)] {
        guard let cg = image.downscaled(to: analysisEdge).cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? [])
                .filter { $0.confidence > 0.05 }
                .map { ($0.identifier, $0.confidence) }
        }.value
    }

    /// Lines of printed text, top to bottom (Live Text's recogniser).
    static func readText(_ image: UIImage) async -> [String] {
        await Perf.measure("Vision read text") { await readTextNow(image) }
    }

    private static func readTextNow(_ image: UIImage) async -> [String] {
        guard let cg = image.downscaled(to: 2400).cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? [])
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
        }.value
    }
}

extension UIImage {
    /// Scaled so the longest edge is at most `edge` points, at scale 1.
    func downscaled(to edge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > edge else { return self }
        let ratio = edge / longest
        let target = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// JPEG for upload: 1600 px on the long edge at 0.7 quality lands around
    /// 250-400 KB, well inside the bucket's 3 MB cap and the free plan's 1 GB.
    func uploadJPEG() -> Data? {
        downscaled(to: 1600).jpegData(compressionQuality: 0.7)
    }
}

extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
