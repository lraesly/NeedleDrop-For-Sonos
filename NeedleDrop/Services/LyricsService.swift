import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "LyricsService")

/// One synced lyric line: timestamp in seconds (from the start of the track)
/// plus the line text. Empty text represents a pause / blank line in the LRC.
struct LyricLine: Equatable, Identifiable {
    let time: Double
    let text: String
    var id: Double { time }
}

/// Parsed lyrics for a track. `synced` is empty when LRCLIB only has a plain
/// transcript, and both are empty when LRCLIB returns the row as instrumental.
struct ParsedLyrics: Equatable {
    let trackId: String
    let synced: [LyricLine]
    let plain: String?

    var isSynced: Bool { !synced.isEmpty }
    var isEmpty: Bool { synced.isEmpty && (plain ?? "").isEmpty }
}

/// Fetches synced lyrics from [LRCLIB](https://lrclib.net). Free, no auth,
/// CC0-licensed corpus. Results are cached in memory keyed by the track's
/// `id` (artist-title pair) so the same track playing on repeat doesn't
/// thrash the API.
actor LyricsService {
    private struct Response: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    private var cache: [String: ParsedLyrics?] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 200

    /// Fetch lyrics for a track. Returns nil for LRCLIB misses (404 or
    /// empty payload) and for instrumental tracks. Negative results are
    /// cached so subsequent re-fetches are free.
    func fetch(for track: TrackInfo) async -> ParsedLyrics? {
        let key = track.id
        if let cached = cache[key] {
            return cached
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
        ]
        if let album = track.album, !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if track.durationSeconds > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: "\(track.durationSeconds)"))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("NeedleDrop/2.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode == 404 {
                insertCache(key: key, value: nil)
                return nil
            }
            guard httpResponse.statusCode == 200 else { return nil }

            let payload = try JSONDecoder().decode(Response.self, from: data)

            if payload.instrumental == true {
                insertCache(key: key, value: nil)
                return nil
            }

            let synced = payload.syncedLyrics.map(Self.parseLRC) ?? []
            let result = ParsedLyrics(
                trackId: key,
                synced: synced,
                plain: payload.plainLyrics
            )
            if result.isEmpty {
                insertCache(key: key, value: nil)
                return nil
            }
            insertCache(key: key, value: result)
            log.debug("Lyrics for \(track.artist) — \(track.title): synced=\(synced.count) lines, plain=\(payload.plainLyrics != nil)")
            return result
        } catch is CancellationError {
            return nil
        } catch {
            log.debug("Lyrics fetch failed for \(track.artist) — \(track.title): \(error.localizedDescription)")
            return nil
        }
    }

    /// Drop everything. Called on sleep alongside the image cache reset.
    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - LRC Parsing

    /// LRCLIB returns the de-facto LRC format: `[mm:ss.xx]Text`, with an
    /// optional fractional-seconds component of 2 or 3 digits, and the
    /// possibility of multiple timestamps on a single line (for repeated
    /// hooks). Metadata-only lines (`[ti:...]`, `[ar:...]`, ...) are dropped.
    private static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let pattern = #"\[(\d+):(\d+)\.(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)
            let range = NSRange(str.startIndex..., in: str)
            let matches = regex.matches(in: str, range: range)
            guard !matches.isEmpty else { continue }

            // Strip every timestamp from the line; the remainder is the
            // visible text. Empty text is intentionally preserved so the
            // scroller has a beat to advance through during silence.
            var text = str
            for match in matches.reversed() {
                if let r = Range(match.range, in: text) { text.removeSubrange(r) }
            }
            let cleaned = text.trimmingCharacters(in: .whitespaces)

            for match in matches {
                guard let mRange = Range(match.range(at: 1), in: str),
                      let sRange = Range(match.range(at: 2), in: str),
                      let fRange = Range(match.range(at: 3), in: str),
                      let min = Int(str[mRange]),
                      let sec = Int(str[sRange]) else { continue }
                let fracStr = String(str[fRange])
                let frac: Double
                if let n = Double(fracStr) {
                    frac = n / pow(10.0, Double(fracStr.count))
                } else {
                    frac = 0
                }
                let time = Double(min) * 60 + Double(sec) + frac
                out.append(LyricLine(time: time, text: cleaned))
            }
        }

        return out.sorted { $0.time < $1.time }
    }

    private func insertCache(key: String, value: ParsedLyrics?) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
