import Foundation

/// The last order list, cleaners and saved addresses on disk, so the home
/// screen draws instantly at launch and then refreshes, instead of waiting on
/// the network every time (launch-to-order-list was ~4.2 s).
///
/// One file per customer, so a shared phone never shows the previous
/// customer's orders. The file holds addresses and notes, so it is written
/// with complete-until-first-unlock protection (readable at launch after the
/// phone's first unlock, encrypted at rest) and removed on sign-out and
/// account deletion.
struct OrderCache: Codable {
    var orders: [Order]
    var cleaners: [Cleaner]
    var addresses: [Address]
    var savedAt: Date

    /// Older than this, the cache is not worth drawing: statuses have moved on.
    static let maxAge: TimeInterval = 7 * 86400

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrderCache", isDirectory: true)
    }

    private static func file(for userId: UUID) -> URL {
        directory.appendingPathComponent("\(userId.uuidString.lowercased()).json")
    }

    static func load(for userId: UUID) -> OrderCache? {
        guard let data = try? Data(contentsOf: file(for: userId)),
              let cache = try? JSONDecoder().decode(OrderCache.self, from: data),
              Date().timeIntervalSince(cache.savedAt) < maxAge else { return nil }
        return cache
    }

    static func save(_ cache: OrderCache, for userId: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: file(for: userId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A cache that cannot be written costs one slow launch, nothing more.
        }
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
