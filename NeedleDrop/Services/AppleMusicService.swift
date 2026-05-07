import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.needledrop", category: "AppleMusic")

/// The title and artist as they appear in the user's Apple Music library.
/// Used so that downstream AppleScript lookups match the actual library entry
/// (e.g. "West End Girls (7'' Mix)") rather than the raw stream title ("WEST END GIRLS").
struct LibraryMatch {
    let title: String
    let artist: String
    /// True if the user has loved (rating value 1) this library track.
    let isLoved: Bool
}

/// Client-side Apple Music integration using MusicKit.
/// Handles authorization, catalog search, and saving tracks to the user's library.
/// No server-side keys or tokens needed — MusicKit handles everything locally.
@MainActor
final class AppleMusicService: ObservableObject {

    @Published var authorizationStatus: MusicAuthorization.Status

    /// User preference: whether to use Apple Music even if authorized.
    /// "Disconnect" just flips this off (you can't programmatically revoke system auth).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appleMusicEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "appleMusicEnabled")
            Task { @MainActor in self.objectWillChange.send() }
        }
    }

    /// True when the system has authorized Apple Music AND the user hasn't disabled it.
    var isConnected: Bool {
        authorizationStatus == .authorized && isEnabled
    }

    init() {
        let status = MusicAuthorization.currentStatus
        authorizationStatus = status
        let enabled = UserDefaults.standard.bool(forKey: "appleMusicEnabled")
        log.info("Apple Music init: authorization=\(String(describing: status)), enabled=\(enabled), isConnected=\(status == .authorized && enabled)")

        // If the user previously connected but system authorization was lost
        // (e.g. reinstall, privacy settings reset), re-request automatically.
        if enabled && status == .notDetermined {
            log.info("Apple Music enabled but not authorized — requesting authorization")
            Task { @MainActor in
                await self.requestAuthorization()
            }
        }
    }

    /// Request system authorization for Apple Music access.
    @discardableResult
    func requestAuthorization() async -> MusicAuthorization.Status {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
        if status == .authorized {
            isEnabled = true
        }
        return status
    }

    /// Disable Apple Music (doesn't revoke system auth, just stops using it).
    func disconnect() {
        isEnabled = false
    }

    /// Strip parenthetical noise from titles that hurts search matching.
    /// Removes things like (Remastered 2002), (67), (Mono), (feat. X), (Live), etc.
    private func cleanTitle(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]"#,
            with: "",
            options: .regularExpression
        )
        return cleaned.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Check if "Live" status differs between two titles.
    /// A live recording is a different track — "Hotel California (Live)" ≠ "Hotel California".
    /// Checks for "Live" as a word boundary match so "Alive" or "Oliver" don't false-positive.
    private func liveStatusMismatch(_ a: String, _ b: String) -> Bool {
        let pattern = #"(?i)\blive\b"#
        let aLive = a.range(of: pattern, options: .regularExpression) != nil
        let bLive = b.range(of: pattern, options: .regularExpression) != nil
        return aLive != bLive
    }

    /// Search catalog, trying exact title first, then cleaned title on miss,
    /// then song-only part (before " - ") for radio stations that send
    /// "SongTitle - AlbumName [Label Year]".
    private func searchTrack(
        title: String, artist: String
    ) async throws -> Song? {
        // First try: exact title
        if let song = try await catalogSearch(title: title, artist: artist),
           song.artwork != nil {
            return song
        }

        // Second try: cleaned title (strip parenthetical/bracketed noise)
        let cleaned = cleanTitle(title)
        if cleaned != title,
           let song = try await catalogSearch(title: cleaned, artist: artist),
           song.artwork != nil {
            return song
        }

        // Third try: strip "Song - Album" format down to just the song part
        let base = cleaned.isEmpty ? title : cleaned
        let parts = base.split(separator: " - ", maxSplits: 1)
        if parts.count == 2 {
            let songOnly = String(parts[0]).trimmingCharacters(in: .whitespaces)
            if !songOnly.isEmpty,
               let song = try await catalogSearch(title: songOnly, artist: artist),
               song.artwork != nil {
                return song
            }
        }

        return nil
    }

    /// Single catalog search attempt — returns best match or nil.
    private func catalogSearch(
        title: String, artist: String
    ) async throws -> Song? {
        let term = "\(artist) \(title)"
        log.info("Catalog search: \(term)")

        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self]
        )
        request.limit = 5

        let response = try await request.response()

        log.info("Search returned \(response.songs.count) results")

        // Prefer an exact artist+title match, fall back to first result
        let match = response.songs.first(where: { song in
            song.title.localizedCaseInsensitiveCompare(title) == .orderedSame &&
            song.artistName.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }) ?? response.songs.first

        if let match {
            log.info("Matched: \(match.artistName) – \(match.title) (id: \(match.id.rawValue))")
        }
        return match
    }

    /// Check if a track is already in the user's Apple Music library.
    ///
    /// Returns the matched library title and artist if found, so that downstream
    /// consumers (e.g. play count AppleScript) can look up the track by its
    /// actual library name rather than the raw stream title.
    func isInLibrary(title: String, artist: String) async -> LibraryMatch? {
        guard isConnected else {
            log.debug("Library check skipped — not connected")
            return nil
        }

        log.info("Library check: \(artist) — \(title)")

        // Try with original title first, then cleaned title
        if let match = await librarySearch(title: title, artist: artist) {
            return match
        }

        let cleaned = cleanTitle(title)
        if cleaned != title {
            log.info("Retrying library check with cleaned title: \(cleaned)")
            return await librarySearch(title: cleaned, artist: artist)
        }

        return nil
    }

    /// Single library search attempt — returns the matched track info if found.
    private func librarySearch(title: String, artist: String) async -> LibraryMatch? {
        // Use MusicKit's native library search (macOS 14+).
        // The raw /v1/me/library/search endpoint returns empty results
        // when Sync Library is off — MusicLibraryRequest queries the
        // local database directly and works regardless.
        if #available(macOS 14.0, *) {
            return await librarySearchNative(title: title, artist: artist)
        } else {
            return await librarySearchAPI(title: title, artist: artist)
        }
    }

    /// Fetch the user's rating for a library song (1 = loved, -1 = disliked,
    /// nil/missing = no rating). Returns nil on error or 404. Costs ~one
    /// HTTPS round-trip per call.
    private func fetchLibraryRating(libraryId: String) async -> Int? {
        guard let url = URL(
            string: "https://api.music.apple.com/v1/me/ratings/library-songs/\(libraryId)"
        ) else { return nil }

        do {
            let request = MusicDataRequest(urlRequest: URLRequest(url: url))
            let response = try await request.response()
            let status = response.urlResponse.statusCode
            // 404 means no rating set — that's "not loved", not an error.
            if status == 404 { return 0 }
            guard (200..<300).contains(status) else {
                log.debug("Rating fetch HTTP \(status) for \(libraryId)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let data = (json?["data"] as? [[String: Any]])?.first
            let attrs = data?["attributes"] as? [String: Any]
            return attrs?["value"] as? Int
        } catch {
            log.debug("Rating fetch failed for \(libraryId): \(error.localizedDescription)")
            return nil
        }
    }

    /// Native MusicKit library search (macOS 14+).
    /// Queries the local library database directly — works even without
    /// iCloud Music Library / Sync Library enabled.
    @available(macOS 14.0, *)
    private func librarySearchNative(title: String, artist: String) async -> LibraryMatch? {
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.title, contains: title)
            let response = try await request.response()

            log.info("Library search (native) returned \(response.items.count) results")

            for song in response.items {
                log.debug("  Result: \(song.artistName) — \(song.title)")
            }

            // Exact match: title + artist both match
            if let song = response.items.first(where: { song in
                song.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                && song.artistName.localizedCaseInsensitiveCompare(artist) == .orderedSame
            }) {
                let isLoved = await fetchLibraryRating(libraryId: song.id.rawValue) == 1
                log.info("Library check: FOUND (exact match), loved=\(isLoved)")
                return LibraryMatch(title: song.title, artist: song.artistName, isLoved: isLoved)
            }

            // Relaxed match: cleaned titles, overlapping artists, live guard
            if let song = response.items.first(where: { song in
                if liveStatusMismatch(song.title, title) { return false }
                let titleMatch = song.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                    || cleanTitle(song.title).localizedCaseInsensitiveCompare(cleanTitle(title)) == .orderedSame
                let artistMatch = song.artistName.localizedStandardContains(artist)
                    || artist.localizedStandardContains(song.artistName)
                return titleMatch && artistMatch
            }) {
                let isLoved = await fetchLibraryRating(libraryId: song.id.rawValue) == 1
                log.info("Library check: FOUND (relaxed match), loved=\(isLoved)")
                return LibraryMatch(title: song.title, artist: song.artistName, isLoved: isLoved)
            }

            log.info("Library check: not found for '\(artist) — \(title)'")
            return nil
        } catch {
            log.warning("Library check (native) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fallback library search using the raw Apple Music API (macOS 13).
    private func librarySearchAPI(title: String, artist: String) async -> LibraryMatch? {
        do {
            var components = URLComponents(
                string: "https://api.music.apple.com/v1/me/library/search"
            )!
            components.queryItems = [
                URLQueryItem(name: "types", value: "library-songs"),
                URLQueryItem(name: "term", value: "\(artist) \(title)"),
                URLQueryItem(name: "limit", value: "10")
            ]

            guard let url = components.url else {
                log.error("Library check: failed to build URL")
                return nil
            }

            let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
            let response = try await dataRequest.response()

            let status = response.urlResponse.statusCode
            guard (200..<300).contains(status) else {
                log.warning("Library check: HTTP \(status)")
                return nil
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let results = json?["results"] as? [String: Any]
            let librarySongs = results?["library-songs"] as? [String: Any]
            let data = librarySongs?["data"] as? [[String: Any]] ?? []

            log.info("Library search (API) returned \(data.count) results")

            func extractAttrs(_ item: [String: Any]) -> (String, String, String)? {
                guard let attrs = item["attributes"] as? [String: Any],
                      let songTitle = attrs["name"] as? String,
                      let songArtist = attrs["artistName"] as? String,
                      let id = item["id"] as? String else { return nil }
                return (songTitle, songArtist, id)
            }

            // Exact match
            if let item = data.first(where: { item in
                guard let (songTitle, songArtist, _) = extractAttrs(item) else { return false }
                return songTitle.localizedCaseInsensitiveCompare(title) == .orderedSame
                    && songArtist.localizedCaseInsensitiveCompare(artist) == .orderedSame
            }), let (songTitle, songArtist, id) = extractAttrs(item) {
                let isLoved = await fetchLibraryRating(libraryId: id) == 1
                log.info("Library check: FOUND (exact match), loved=\(isLoved)")
                return LibraryMatch(title: songTitle, artist: songArtist, isLoved: isLoved)
            }

            // Relaxed match
            if let item = data.first(where: { item in
                guard let (songTitle, songArtist, _) = extractAttrs(item) else { return false }
                if liveStatusMismatch(songTitle, title) { return false }
                let titleMatch = songTitle.localizedCaseInsensitiveCompare(title) == .orderedSame
                    || cleanTitle(songTitle).localizedCaseInsensitiveCompare(cleanTitle(title)) == .orderedSame
                let artistMatch = songArtist.localizedStandardContains(artist)
                    || artist.localizedStandardContains(songArtist)
                return titleMatch && artistMatch
            }), let (songTitle, songArtist, id) = extractAttrs(item) {
                let isLoved = await fetchLibraryRating(libraryId: id) == 1
                log.info("Library check: FOUND (relaxed match), loved=\(isLoved)")
                return LibraryMatch(title: songTitle, artist: songArtist, isLoved: isLoved)
            }

            log.info("Library check: not found for '\(artist) — \(title)'")
            return nil
        } catch {
            log.warning("Library check (API) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Search the Apple Music catalog for a track, add it to the user's library,
    /// and optionally love it. Pass `love: false` for background auto-adds where
    /// the user hasn't expressed an explicit preference for the track.
    func searchAndSave(title: String, artist: String, love: Bool = true) async -> ServiceSaveResult {
        guard isConnected else {
            log.warning("Save skipped — Apple Music not connected")
            return ServiceSaveResult(
                service: "apple_music",
                success: false,
                message: "Apple Music not connected",
                trackName: nil,
                trackUrl: nil
            )
        }

        log.info("Saving: \(artist) – \(title)")

        do {
            guard let song = try await searchTrack(title: title, artist: artist) else {
                log.warning("Track not found on Apple Music")
                return ServiceSaveResult(
                    service: "apple_music",
                    success: false,
                    message: "Track not found on Apple Music",
                    trackName: nil,
                    trackUrl: nil
                )
            }

            // MusicLibrary.add(_:) is unavailable on macOS; use the
            // Apple Music API directly via MusicDataRequest instead.
            log.info("Adding to library: \(song.id.rawValue)")
            var addComponents = URLComponents(
                string: "https://api.music.apple.com/v1/me/library"
            )!
            addComponents.queryItems = [
                URLQueryItem(name: "ids[songs]", value: song.id.rawValue)
            ]
            var addRequest = URLRequest(url: addComponents.url!)
            addRequest.httpMethod = "POST"

            let addDataRequest = MusicDataRequest(urlRequest: addRequest)
            let addResponse = try await addDataRequest.response()

            guard (200..<300).contains(addResponse.urlResponse.statusCode) else {
                log.error("Add to library failed: HTTP \(addResponse.urlResponse.statusCode)")
                return ServiceSaveResult(
                    service: "apple_music",
                    success: false,
                    message: "Apple Music API error (\(addResponse.urlResponse.statusCode))",
                    trackName: song.title,
                    trackUrl: nil
                )
            }

            if love {
                // Also "Love" the track so it shows a heart in Apple Music.
                // PUT /v1/me/ratings/songs/{id} with value=1
                log.info("Rating track: \(song.id.rawValue)")
                let ratingURL = URL(
                    string: "https://api.music.apple.com/v1/me/ratings/songs/\(song.id.rawValue)"
                )!
                var ratingRequest = URLRequest(url: ratingURL)
                ratingRequest.httpMethod = "PUT"
                ratingRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                ratingRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                    "type": "rating",
                    "attributes": ["value": 1]
                ])

                let ratingDataRequest = MusicDataRequest(urlRequest: ratingRequest)
                _ = try? await ratingDataRequest.response()
                // Rating is best-effort — don't fail the save if it errors
            }

            log.info("Saved to Apple Music: \(song.title)")
            return ServiceSaveResult(
                service: "apple_music",
                success: true,
                message: "Saved to Apple Music",
                trackName: song.title,
                trackUrl: song.url?.absoluteString
            )
        } catch {
            log.error("Apple Music save failed: \(error.localizedDescription)")
            return ServiceSaveResult(
                service: "apple_music",
                success: false,
                message: error.localizedDescription,
                trackName: nil,
                trackUrl: nil
            )
        }
    }
}
