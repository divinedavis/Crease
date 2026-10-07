import ARKit

/// Measures a pile of laundry with the LiDAR scanner (iPhone Pro models).
///
/// ARKit finds the floor as a horizontal plane; on "Measure", a few depth
/// frames are back-projected into world points inside the centre of the view,
/// and PileVolume turns the points above the floor into cubic feet. Depth
/// never leaves the phone and nothing is stored.
@MainActor
final class PileScanner: NSObject, ObservableObject {
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    @Published private(set) var floorFound = false
    @Published private(set) var measuring = false
    @Published private(set) var cubicFeet: Double?

    private weak var session: ARSession?
    private var floorY: Float?

    func attach(_ session: ARSession) {
        self.session = session
        session.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.frameSemantics = [.sceneDepth]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session?.pause() }

    /// Combine a handful of frames so one noisy frame does not decide it.
    func measure() async {
        guard let session, let floorY else { return }
        measuring = true
        defer { measuring = false }
        var points: [SIMD3<Float>] = []
        for _ in 0..<6 {
            if let frame = session.currentFrame, let depth = frame.sceneDepth {
                let camera = frame.camera
                points += await Task.detached(priority: .userInitiated) {
                    Self.worldPoints(depth: depth, camera: camera)
                }.value
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard !points.isEmpty else { return }
        cubicFeet = PileVolume.cubicFeet(points: points, floorY: floorY)
    }

    /// High-confidence depth pixels in the middle 60% of the frame, as world points.
    nonisolated private static func worldPoints(depth: ARDepthData, camera: ARCamera) -> [SIMD3<Float>] {
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return [] }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confidence: UnsafeMutableRawPointer?
        var confRowBytes = 0
        if let conf = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confidence = CVPixelBufferGetBaseAddress(conf)
            confRowBytes = CVPixelBufferGetBytesPerRow(conf)
        }
        defer { if let conf = depth.confidenceMap { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        // Intrinsics are for the full camera image; scale them to the depth map.
        let scale = Float(w) / Float(camera.imageResolution.width)
        let k = camera.intrinsics
        let fx = k[0][0] * scale, fy = k[1][1] * scale, cx = k[2][0] * scale, cy = k[2][1] * scale
        let toWorld = camera.transform

        var out: [SIMD3<Float>] = []
        out.reserveCapacity((w * h) / 8)
        for v in stride(from: h / 5, to: h * 4 / 5, by: 2) {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)
            for u in stride(from: w / 5, to: w * 4 / 5, by: 2) {
                if let confidence {
                    let c = confidence.advanced(by: v * confRowBytes + u).load(as: UInt8.self)
                    if c < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                }
                let d = row[u]
                guard d.isFinite, d > 0.2, d < 3 else { continue }
                // Camera space: x right, y up, looking down -z.
                let p = SIMD4<Float>((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d, 1)
                let world = toWorld * p
                out.append(SIMD3(world.x, world.y, world.z))
            }
        }
        return out
    }
}

extension PileScanner: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let ys = anchors.compactMap { anchor -> Float? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            return plane.transform.columns.3.y
        }
        guard let lowest = ys.min() else { return }
        Task { @MainActor in
            // The floor is the lowest horizontal surface; a table or the top of
            // the pile itself is not.
            if self.floorY == nil || lowest < self.floorY! { self.floorY = lowest }
            self.floorFound = true
        }
    }
}
