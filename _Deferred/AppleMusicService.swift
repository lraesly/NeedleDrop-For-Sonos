import Foundation
import MusicKit

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
            objectWillChange.send()
        }
    }

    /// True when the system has authorized Apple Music AND the user hasn't disabled it.
    var isConnected: Bool {
        authorizationStatus == .authorized && isEnabled
    }

    init() {
        authorizationStatus = MusicAuthorization.currentStatus
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

    /// Search catalog, trying exact title first, then cleaned title on miss.
    private func searchTrack(
        title: String, artist: String
    ) async throws -> Song? {
        // First try: exact title
        if let song = try await catalogSearch(title: title, artist: artist) {
            return song
        }

        // Second try: cleaned title (strip parenthetical noise)
        let cleaned = cleanTitle(title)
        if cleaned != title {
            return try await catalogSearch(title: cleaned, artist: artist)
        }

        return nil
    }

    /// Single catalog search attempt — returns best match or nil.
    private func catalogSearch(
        title: String, artist: String
    ) async throws -> Song? {
        var request = MusicCatalogSearchRequest(
            term: "\(artist) \(title)",
            types: [Song.self]
        )
        request.limit = 5

        let response = try await request.response()

        // Prefer an exact artist+title match, fall back to first result
        return response.songs.first(where: { song in
            song.title.localizedCaseInsensitiveCompare(title) == .orderedSame &&
            song.artistName.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }) ?? response.songs.first
    }

    /// Search the Apple Music catalog for a track, add it to the user's library, and love it.
    func searchAndSave(title: String, artist: String) async -> ServiceSaveResult {
        guard isConnected else {
            return ServiceSaveResult(
                success: false,
                message: "Apple Music not connected",
                trackName: nil,
                trackUrl: nil
            )
        }

        do {
            guard let song = try await searchTrack(title: title, artist: artist) else {
                return ServiceSaveResult(
                    success: false,
                    message: "Track not found on Apple Music",
                    trackName: nil,
                    trackUrl: nil
                )
            }

            // MusicLibrary.add(_:) is unavailable on macOS; use the
            // Apple Music API directly via MusicDataRequest instead.
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
                return ServiceSaveResult(
                    success: false,
                    message: "Apple Music API error (\(addResponse.urlResponse.statusCode))",
                    trackName: song.title,
                    trackUrl: nil
                )
            }

            // Also "Love" the track so it shows a heart in Apple Music.
            // PUT /v1/me/ratings/songs/{id} with value=1
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
            _ = try await ratingDataRequest.response()

            return ServiceSaveResult(
                success: true,
                message: "Saved to Apple Music",
                trackName: song.title,
                trackUrl: song.url?.absoluteString
            )
        } catch {
            return ServiceSaveResult(
                success: false,
                message: error.localizedDescription,
                trackName: nil,
                trackUrl: nil
            )
        }
    }
}
