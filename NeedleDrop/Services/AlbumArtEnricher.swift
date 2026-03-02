import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "AlbumArtEnricher")

/// Enriches album art via the iTunes Search API.
///
/// Sonos often provides station logos instead of per-track album art for radio.
/// The iTunes Search API is free, fast, requires no auth, and returns high-quality
/// artwork URLs for most commercial tracks.
actor AlbumArtEnricher {

    /// In-memory cache: `"artist-title"` → URL (or nil for known misses).
    private var cache: [String: URL?] = [:]

    /// Look up album art for a track via iTunes Search API.
    ///
    /// Returns a 600×600 artwork URL on hit, `nil` on miss or timeout.
    /// Results are cached in memory (including negative results).
    /// Times out after 1.5s so a slow response doesn't delay track updates.
    func searchArt(artist: String, title: String) async -> URL? {
        let cacheKey = "\(artist)-\(title)"

        // Check cache (including negative hits)
        if let cached = cache[cacheKey] {
            return cached
        }

        do {
            let url = try await fetchArt(artist: artist, title: title)
            cache[cacheKey] = url
            if let url {
                log.debug("iTunes art for \(artist) - \(title): \(url)")
            } else {
                log.debug("No iTunes art found for \(artist) - \(title)")
            }
            return url
        } catch is CancellationError {
            return nil
        } catch {
            log.debug("iTunes art lookup failed for \(artist) - \(title): \(error.localizedDescription)")
            // Don't cache timeouts — might succeed next time
            if !(error is URLError && (error as! URLError).code == .timedOut) {
                cache[cacheKey] = nil as URL?
            }
            return nil
        }
    }

    /// Clear the cache (useful after sleep/wake when network may have changed).
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func fetchArt(artist: String, title: String) async throws -> URL? {
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
        request.setValue("NeedleDrop/2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        let result = try JSONDecoder().decode(ITunesSearchResult.self, from: data)
        guard let artURL = result.results.first?.artworkUrl100, !artURL.isEmpty else { return nil }

        // Upscale from 100×100 to 600×600
        let highRes = artURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: highRes)
    }
}

// MARK: - iTunes API Response

private struct ITunesSearchResult: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let artworkUrl100: String?
}
