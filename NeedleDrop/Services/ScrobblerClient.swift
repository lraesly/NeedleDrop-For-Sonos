import Foundation
import Network
import os

private let log = Logger(subsystem: "com.needledrop", category: "ScrobblerClient")

/// Thin REST client for the remote NeedleDrop scrobbler.
/// Discovers the scrobbler via Bonjour (`_needledrop._tcp`), then
/// provides getFilters, setFilters, setLastFMCredentials, getRecentScrobbles.
@MainActor
final class ScrobblerClient: ObservableObject {
    @Published var config: ScrobblerConfig?
    @Published var isSearching = false

    private var browser: NWBrowser?

    // MARK: - Bonjour Discovery

    /// Search for a NeedleDrop scrobbler on the local network via Bonjour.
    func discoverScrobbler() {
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_needledrop._tcp", domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        log.info("Found scrobbler: \(name) (\(type) in \(domain))")
                        // Resolve the service to get host/port/TXT
                        self.resolveService(result)
                    }
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.isSearching = false
                }
            }
        }

        browser.start(queue: .main)

        // Stop searching after 10 seconds
        Task {
            try? await Task.sleep(for: .seconds(10))
            stopDiscovery()
        }
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func resolveService(_ result: NWBrowser.Result) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = endpoint {
                    let hostStr = "\(host)"
                    let portNum = Int(port.rawValue)
                    Task { @MainActor in
                        // Extract service name from the endpoint
                        var name = "Scrobbler"
                        if case let .service(serviceName, _, _, _) = result.endpoint {
                            name = serviceName
                        }
                        self?.config = ScrobblerConfig(
                            host: hostStr,
                            port: portNum,
                            token: "",
                            name: name
                        )
                        self?.isSearching = false
                        self?.stopDiscovery()
                        log.info("Resolved scrobbler: \(name) at \(hostStr):\(portNum)")
                    }
                }
                connection.cancel()
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    /// Manually set scrobbler config (for when discovery already happened).
    func setConfig(_ config: ScrobblerConfig) {
        self.config = config
        persistConfig()
    }

    func disconnect() {
        config = nil
        UserDefaults.standard.removeObject(forKey: "scrobblerConfig")
    }

    // MARK: - Persistence

    func persistConfig() {
        guard let config else { return }
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "scrobblerConfig")
        }
    }

    func loadPersistedConfig() {
        if let data = UserDefaults.standard.data(forKey: "scrobblerConfig"),
           let saved = try? JSONDecoder().decode(ScrobblerConfig.self, from: data) {
            self.config = saved
        }
    }

    // MARK: - API Calls

    /// Get scrobble filter rules from the remote scrobbler.
    func getFilters() async throws -> (minDuration: Int, rules: [FilterRule]) {
        let data = try await get("/api/config/filters")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let minDuration = json["min_duration"] as? Int,
              let rulesArray = json["rules"] as? [[String: Any]] else {
            throw ScrobblerError.invalidResponse
        }

        let rules = rulesArray.compactMap { dict -> FilterRule? in
            guard let field = dict["field"] as? String,
                  let mode = dict["mode"] as? String,
                  let value = dict["value"] as? String else { return nil }

            let type: FilterRule.FilterType = field == "artist" ? .artistExclude : .titleExclude
            // Convert mode+value back to pattern for display
            let pattern: String
            switch mode {
            case "exact": pattern = value
            case "starts_with": pattern = "\(value)*"
            case "contains": pattern = "*\(value)*"
            case "regex": pattern = value
            default: pattern = value
            }
            return FilterRule(pattern: pattern, type: type)
        }

        return (minDuration, rules)
    }

    /// Push updated filter rules to the remote scrobbler.
    func setFilters(minDuration: Int, rules: [FilterRule]) async throws {
        // Convert FilterRules to the API format (field, mode, value)
        let apiRules = rules.map { rule -> [String: String] in
            let field = rule.type == .artistExclude ? "artist" : "title"
            // Simple heuristic: treat as exact match unless it looks like a regex
            return ["field": field, "mode": "regex", "value": rule.pattern]
        }

        let body: [String: Any] = [
            "min_duration": minDuration,
            "rules": apiRules,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(method: "PUT", path: "/api/config/filters", body: bodyData)
    }

    /// Push Last.fm credentials to the remote scrobbler.
    func setLastFMCredentials(apiKey: String, apiSecret: String, username: String, passwordHash: String) async throws {
        let body: [String: String] = [
            "api_key": apiKey,
            "api_secret": apiSecret,
            "username": username,
            "password_hash": passwordHash,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(method: "PUT", path: "/api/config/lastfm", body: bodyData)
    }

    /// Get recent scrobbles from the remote scrobbler.
    func getRecentScrobbles(limit: Int = 20) async throws -> [[String: Any]] {
        let data = try await get("/api/scrobbles/recent?limit=\(limit)")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScrobblerError.invalidResponse
        }
        return array
    }

    /// Check scrobbler health.
    func getStatus() async throws -> Bool {
        let data = try await get("/api/status")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusStr = json["status"] as? String else {
            return false
        }
        return statusStr == "ok"
    }

    // MARK: - HTTP Helpers

    private func get(_ path: String) async throws -> Data {
        try await request(method: "GET", path: path, body: nil)
    }

    private func request(method: String, path: String, body: Data?) async throws -> Data {
        guard let config else { throw ScrobblerError.notConnected }

        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10

        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ScrobblerError.httpError(statusCode)
        }

        return data
    }

    // MARK: - Errors

    enum ScrobblerError: Error, LocalizedError {
        case notConnected
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Scrobbler not connected"
            case .invalidResponse: return "Invalid response from scrobbler"
            case .httpError(let code): return "Scrobbler HTTP error: \(code)"
            }
        }
    }
}

