import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "ArtOverrideStore")

/// Persists user choices about album art:
/// - **preferred** — per `(artist, title)`, a specific URL the user picked from
///   the alternative-art picker, overriding whatever iTunes Search returns.
/// - **ignored** — full URLs the user told the app to never display. Used to
///   prevent a wrong iTunes hit from coming back on the next track lookup.
///
/// Reads and writes are thread-safe (lock-protected) so the actor-isolated
/// `AlbumArtEnricher` can consult the store synchronously without hopping
/// to the main actor.
final class ArtOverrideStore: @unchecked Sendable {
    static let shared = ArtOverrideStore()

    private let preferredKey = "albumArt.preferredOverrides"
    private let ignoredKey = "albumArt.ignoredURLs"

    private let lock = NSLock()
    private var _preferred: [String: URL] = [:]
    private var _ignored: Set<String> = []

    init() { load() }

    /// Canonical (artist, title) key — lowercased & trimmed so casing /
    /// whitespace variants from different streaming sources collapse onto
    /// the same override entry.
    static func key(artist: String, title: String) -> String {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(a)|\(t)"
    }

    // MARK: - Preferred

    func preferredArt(artist: String, title: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return _preferred[Self.key(artist: artist, title: title)]
    }

    func setPreferred(artist: String, title: String, url: URL) {
        lock.lock()
        _preferred[Self.key(artist: artist, title: title)] = url
        lock.unlock()
        persist()
    }

    func clearPreferred(artist: String, title: String) {
        lock.lock()
        _preferred.removeValue(forKey: Self.key(artist: artist, title: title))
        lock.unlock()
        persist()
    }

    // MARK: - Ignored

    func isIgnored(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _ignored.contains(url.absoluteString)
    }

    func markIgnored(_ url: URL) {
        lock.lock()
        _ignored.insert(url.absoluteString)
        lock.unlock()
        persist()
    }

    func clearIgnored(_ url: URL) {
        lock.lock()
        _ignored.remove(url.absoluteString)
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: preferredKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            lock.lock()
            _preferred = dict.compactMapValues { URL(string: $0) }
            lock.unlock()
        }
        if let data = defaults.data(forKey: ignoredKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            lock.lock()
            _ignored = Set(arr)
            lock.unlock()
        }
        log.info("Loaded \(self._preferred.count) preferred + \(self._ignored.count) ignored art overrides")
    }

    private func persist() {
        let defaults = UserDefaults.standard
        lock.lock()
        let preferredSnapshot = _preferred.mapValues { $0.absoluteString }
        let ignoredSnapshot = Array(_ignored)
        lock.unlock()

        if let data = try? JSONEncoder().encode(preferredSnapshot) {
            defaults.set(data, forKey: preferredKey)
        }
        if let data = try? JSONEncoder().encode(ignoredSnapshot) {
            defaults.set(data, forKey: ignoredKey)
        }
    }
}
