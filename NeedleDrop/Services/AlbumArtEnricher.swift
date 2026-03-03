import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "AlbumArtEnricher")

/// Result of an iTunes Search API enrichment lookup.
struct EnrichmentResult {
    let artURL: URL?
    let durationSeconds: Int?
}

/// Enriches album art and track duration via the iTunes Search API.
///
/// Sonos often provides station logos instead of per-track album art for radio.
/// The iTunes Search API is free, fast, requires no auth, and returns high-quality
/// artwork URLs and track durations for most commercial tracks.
actor AlbumArtEnricher {

    /// In-memory cache: `"artist-title"` → enrichment result (or nil for known misses).
    /// Capped at `maxCacheEntries` with FIFO eviction to prevent unbounded growth.
    private var cache: [String: EnrichmentResult?] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 500

    /// Look up album art and duration for a track via iTunes Search API.
    ///
    /// Returns art URL (600x600) and duration on hit. Results are cached
    /// in memory (including negative results).
    /// Times out after 1.5s so a slow response doesn't delay track updates.
    func searchArt(artist: String, title: String) async -> EnrichmentResult? {
        let cacheKey = "\(artist)-\(title)"

        // Check cache (including negative hits)
        if let cached = cache[cacheKey] {
            return cached
        }

        do {
            let result = try await fetchEnrichment(artist: artist, title: title)
            insertCache(key: cacheKey, value: result)
            if let result {
                log.debug("iTunes enrichment for \(artist) - \(title): art=\(result.artURL?.absoluteString ?? "nil"), duration=\(result.durationSeconds ?? 0)s")
            } else {
                log.debug("No iTunes result for \(artist) - \(title)")
            }
            return result
        } catch is CancellationError {
            return nil
        } catch {
            log.debug("iTunes lookup failed for \(artist) - \(title): \(error.localizedDescription)")
            // Don't cache timeouts — might succeed next time
            if !(error is URLError && (error as! URLError).code == .timedOut) {
                insertCache(key: cacheKey, value: nil)
            }
            return nil
        }
    }

    /// Clear the cache (useful after sleep/wake when network may have changed).
    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Insert into cache with FIFO eviction when over limit.
    private func insertCache(key: String, value: EnrichmentResult?) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Private

    private func fetchEnrichment(artist: String, title: String) async throws -> EnrichmentResult? {
        let term = "\(artist) \(title)"
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1"),
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("NeedleDrop/2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        let result = try JSONDecoder().decode(ITunesSearchResult.self, from: data)
        guard let track = result.results.first else { return nil }

        // Build art URL (upscale from 100×100 to 600×600)
        var artURL: URL?
        if let artStr = track.artworkUrl100, !artStr.isEmpty {
            let highRes = artStr.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            artURL = URL(string: highRes)
        }

        // Duration in milliseconds → seconds
        let durationSeconds: Int?
        if let millis = track.trackTimeMillis, millis > 0 {
            durationSeconds = millis / 1000
        } else {
            durationSeconds = nil
        }

        // Return nil if we got nothing useful
        if artURL == nil && durationSeconds == nil { return nil }

        return EnrichmentResult(artURL: artURL, durationSeconds: durationSeconds)
    }
}

// MARK: - iTunes API Response

private struct ITunesSearchResult: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let artworkUrl100: String?
    let trackTimeMillis: Int?
}
