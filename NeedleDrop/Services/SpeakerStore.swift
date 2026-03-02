import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "SpeakerStore")

/// A cached speaker entry for fast reconnection on launch.
struct CachedSpeaker: Codable, Equatable {
    let uuid: String
    let ip: String
    let roomName: String
    let lastSeen: Date
}

/// Persists known Sonos speaker IPs/UUIDs to UserDefaults for fast reconnection.
/// On launch, the discovery service probes these IPs directly instead of waiting
/// for SSDP multicast, which can be slow on macOS.
final class SpeakerStore {
    private static let cacheKey = "cachedSpeakers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadCachedSpeakers() -> [CachedSpeaker] {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return [] }
        do {
            return try JSONDecoder().decode([CachedSpeaker].self, from: data)
        } catch {
            log.warning("Failed to decode cached speakers: \(error.localizedDescription)")
            return []
        }
    }

    func cacheSpeaker(_ device: SonosDevice) {
        var cached = loadCachedSpeakers()
        let entry = CachedSpeaker(
            uuid: device.uuid,
            ip: device.ip,
            roomName: device.roomName,
            lastSeen: Date()
        )

        if let index = cached.firstIndex(where: { $0.uuid == device.uuid }) {
            cached[index] = entry
        } else {
            cached.append(entry)
        }

        // Prune speakers not seen in 30 days
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        cached.removeAll { $0.lastSeen < cutoff }

        save(cached)
    }

    private func save(_ speakers: [CachedSpeaker]) {
        do {
            let data = try JSONEncoder().encode(speakers)
            defaults.set(data, forKey: Self.cacheKey)
        } catch {
            log.warning("Failed to encode cached speakers: \(error.localizedDescription)")
        }
    }
}
