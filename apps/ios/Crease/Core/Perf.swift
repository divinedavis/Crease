import os

/// Signposts for Instruments (Points of Interest / os_signpost), so the slow
/// paths can be timed on a real phone instead of guessed at: order loads,
/// on-device Vision and the order cache. Near-free when Instruments is not
/// recording.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.divinedavis.crease", category: .pointsOfInterest)

    static func measure<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await work()
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
