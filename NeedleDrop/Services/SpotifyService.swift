import AppKit
import Foundation
import CryptoKit
import os
import Security

private let log = Logger(subsystem: "com.needledrop", category: "SpotifyService")

/// Local Spotify Web API client using PKCE OAuth (no client secret needed).
/// Handles authorization, token management, search, and library saves.
@MainActor
final class SpotifyService: ObservableObject {

    @Published var isConnected: Bool = false

    /// User-provided Spotify app Client ID (stored in UserDefaults).
    var clientId: String {
        get { UserDefaults.standard.string(forKey: "spotifyClientId") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "spotifyClientId")
            objectWillChange.send()
        }
    }

    var hasClientId: Bool { !clientId.isEmpty }

    // MARK: - Token State

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    // MARK: - PKCE State

    private var codeVerifier: String?

    // MARK: - Keychain Keys

    private static let keychainService = "com.needledrop.spotify"
    private static let accessTokenKey = "accessToken"
    private static let refreshTokenKey = "refreshToken"
    private static let tokenExpiryKey = "tokenExpiry"

    // MARK: - Init

    init() {
        loadTokensFromKeychain()
        isConnected = accessToken != nil && !(tokenExpired && refreshToken == nil)
    }

    private var tokenExpired: Bool {
        guard let expiry = tokenExpiry else { return true }
        return Date() >= expiry
    }

    // MARK: - Authorization (PKCE)

    /// Start the Spotify OAuth PKCE flow. Opens the browser for authorization
    /// and waits for the callback on localhost.
    func authorize() async throws {
        guard hasClientId else {
            throw SpotifyError.noClientId
        }

        // Generate PKCE code verifier + challenge
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        // Build the auth URL
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: OAuthCallbackServer.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: "user-library-modify user-library-read"),
        ]

        guard let authURL = components.url else {
            throw SpotifyError.invalidURL
        }

        // Start local callback server
        let callbackServer = OAuthCallbackServer()

        // Open browser for user authorization
        NSWorkspace.shared.open(authURL)

        // Wait for the redirect callback
        let code: String
        do {
            code = try await callbackServer.waitForCallback()
        } catch {
            callbackServer.stop()
            throw error
        }
        callbackServer.stop()

        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code)
    }

    /// Disconnect Spotify (clear tokens).
    func disconnect() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        codeVerifier = nil
        isConnected = false
        deleteTokensFromKeychain()
        log.info("Spotify disconnected")
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String) async throws {
        guard let verifier = codeVerifier else {
            throw SpotifyError.noPKCEVerifier
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthCallbackServer.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ]
        request.httpBody = body.urlEncoded.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.error("Token exchange failed: HTTP \(statusCode)")
            throw SpotifyError.tokenExchangeFailed
        }

        try parseTokenResponse(data)
        isConnected = true
        codeVerifier = nil
        log.info("Spotify connected via PKCE")
    }

    /// Refresh the access token using the stored refresh token.
    private func refreshAccessToken() async throws {
        guard let refreshToken else {
            throw SpotifyError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        request.httpBody = body.urlEncoded.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.error("Token refresh failed: HTTP \(statusCode)")
            disconnect()
            throw SpotifyError.tokenRefreshFailed
        }

        try parseTokenResponse(data)
        log.info("Spotify token refreshed")
    }

    private func parseTokenResponse(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw SpotifyError.invalidTokenResponse
        }

        self.accessToken = accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60)) // 60s buffer
        if let newRefreshToken = json["refresh_token"] as? String {
            self.refreshToken = newRefreshToken
        }

        saveTokensToKeychain()
    }

    /// Get a valid access token, refreshing if needed.
    private func validAccessToken() async throws -> String {
        if let token = accessToken, !tokenExpired {
            return token
        }
        try await refreshAccessToken()
        guard let token = accessToken else {
            throw SpotifyError.noAccessToken
        }
        return token
    }

    // MARK: - API: Search & Save

    /// Search the Spotify catalog for a track by title and artist.
    /// Tries exact query first, then cleaned title (stripping parentheticals).
    func searchAndSave(title: String, artist: String) async -> ServiceSaveResult {
        guard isConnected else {
            return ServiceSaveResult(
                service: "spotify",
                success: false,
                message: "Spotify not connected",
                trackName: nil,
                trackUrl: nil
            )
        }

        do {
            // Search with exact title
            var track = try await searchTrack(title: title, artist: artist)

            // Retry with cleaned title if no match
            if track == nil {
                let cleaned = cleanTitle(title)
                if cleaned != title {
                    track = try await searchTrack(title: cleaned, artist: artist)
                }
            }

            guard let found = track else {
                return ServiceSaveResult(
                    service: "spotify",
                    success: false,
                    message: "Track not found on Spotify",
                    trackName: nil,
                    trackUrl: nil
                )
            }

            // Save to library
            try await saveToLibrary(trackId: found.id)

            return ServiceSaveResult(
                service: "spotify",
                success: true,
                message: "Saved to Spotify",
                trackName: found.name,
                trackUrl: found.externalURL
            )
        } catch {
            return ServiceSaveResult(
                service: "spotify",
                success: false,
                message: error.localizedDescription,
                trackName: nil,
                trackUrl: nil
            )
        }
    }

    private struct SpotifyTrack {
        let id: String
        let name: String
        let externalURL: String?
    }

    private func searchTrack(title: String, artist: String) async throws -> SpotifyTrack? {
        let token = try await validAccessToken()

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "artist:\(artist) track:\(title)"),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "5"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SpotifyError.searchFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]],
              let first = items.first else {
            return nil
        }

        let id = first["id"] as? String ?? ""
        let name = first["name"] as? String ?? ""
        let externalURLs = first["external_urls"] as? [String: String]
        let spotifyURL = externalURLs?["spotify"]

        return SpotifyTrack(id: id, name: name, externalURL: spotifyURL)
    }

    private func saveToLibrary(trackId: String) async throws {
        let token = try await validAccessToken()

        var components = URLComponents(string: "https://api.spotify.com/v1/me/tracks")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: trackId),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SpotifyError.saveFailed
        }
    }

    // MARK: - Title Cleaning

    /// Strip parenthetical noise from titles that hurts search matching.
    /// Removes things like (Remastered 2002), (feat. X), (Live), etc.
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

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded
    }

    // MARK: - Keychain

    private func saveTokensToKeychain() {
        if let accessToken {
            setKeychainItem(key: Self.accessTokenKey, value: accessToken)
        }
        if let refreshToken {
            setKeychainItem(key: Self.refreshTokenKey, value: refreshToken)
        }
        if let tokenExpiry {
            let ts = String(tokenExpiry.timeIntervalSince1970)
            setKeychainItem(key: Self.tokenExpiryKey, value: ts)
        }
    }

    private func loadTokensFromKeychain() {
        accessToken = getKeychainItem(key: Self.accessTokenKey)
        refreshToken = getKeychainItem(key: Self.refreshTokenKey)
        if let expiryStr = getKeychainItem(key: Self.tokenExpiryKey),
           let interval = Double(expiryStr) {
            tokenExpiry = Date(timeIntervalSince1970: interval)
        }
    }

    private func deleteTokensFromKeychain() {
        for key in [Self.accessTokenKey, Self.refreshTokenKey, Self.tokenExpiryKey] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private func setKeychainItem(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary) // Remove existing

        var newItem = query
        newItem[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(newItem as CFDictionary, nil)
    }

    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Errors

    enum SpotifyError: Error, LocalizedError {
        case noClientId
        case invalidURL
        case noPKCEVerifier
        case tokenExchangeFailed
        case tokenRefreshFailed
        case invalidTokenResponse
        case noRefreshToken
        case noAccessToken
        case searchFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .noClientId: return "Set your Spotify Client ID first"
            case .invalidURL: return "Invalid authorization URL"
            case .noPKCEVerifier: return "PKCE verification failed"
            case .tokenExchangeFailed: return "Could not exchange authorization code"
            case .tokenRefreshFailed: return "Spotify session expired — please reconnect"
            case .invalidTokenResponse: return "Invalid token response from Spotify"
            case .noRefreshToken: return "No refresh token — please reconnect"
            case .noAccessToken: return "No access token available"
            case .searchFailed: return "Spotify search failed"
            case .saveFailed: return "Could not save track to Spotify library"
            }
        }
    }
}

// MARK: - Helpers

private extension Data {
    /// Base64 URL-safe encoding (no padding).
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Dictionary where Key == String, Value == String {
    /// URL-encode dictionary as form body.
    var urlEncoded: String {
        map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        .joined(separator: "&")
    }
}
