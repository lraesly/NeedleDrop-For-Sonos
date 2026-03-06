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

    /// NetServiceBrowser-based discovery (reliable TXT record delivery).
    private var serviceBrowser: NetServiceBrowser?
    private var browserDelegate: BonjourBrowserDelegate?
    /// Keep the discovered service alive during resolution.
    private var resolvingService: NetService?
    private var resolveDelegate: BonjourResolveDelegate?
    private var isResolving = false

    // MARK: - Bonjour Discovery

    /// Search for a NeedleDrop scrobbler on the local network via Bonjour.
    func discoverScrobbler() {
        isSearching = true

        let delegate = BonjourBrowserDelegate { [weak self] service in
            Task { @MainActor in
                self?.handleFoundService(service)
            }
        }
        self.browserDelegate = delegate

        let browser = NetServiceBrowser()
        browser.delegate = delegate
        self.serviceBrowser = browser

        browser.searchForServices(ofType: "_needledrop._tcp.", inDomain: "")

        // Stop searching after 10 seconds
        Task {
            try? await Task.sleep(for: .seconds(10))
            stopDiscovery()
        }
    }

    func stopDiscovery() {
        serviceBrowser?.stop()
        serviceBrowser = nil
        browserDelegate = nil
        resolvingService = nil
        resolveDelegate = nil
        isSearching = false
        isResolving = false
    }

    private func handleFoundService(_ service: NetService) {
        guard config == nil, !isResolving else { return }
        isResolving = true
        log.info("Found scrobbler: \(service.name)")

        // Keep the service alive and resolve it to get address + TXT record
        self.resolvingService = service

        let delegate = BonjourResolveDelegate(
            onResolved: { [weak self] resolvedService in
                Task { @MainActor in
                    self?.handleResolvedService(resolvedService)
                }
            },
            onError: { [weak self] errorDict in
                Task { @MainActor in
                    log.warning("Service resolution failed: \(errorDict)")
                    self?.isResolving = false
                    self?.resolvingService = nil
                    self?.resolveDelegate = nil
                }
            }
        )
        self.resolveDelegate = delegate
        service.delegate = delegate
        service.resolve(withTimeout: 5)
    }

    private func handleResolvedService(_ service: NetService) {
        // Extract IP from resolved addresses
        guard let addresses = service.addresses, !addresses.isEmpty else {
            log.warning("Service resolved but no addresses found")
            isResolving = false
            return
        }

        var hostStr: String?
        for addressData in addresses {
            addressData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                let family = baseAddress.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    let sockaddrIn = baseAddress.assumingMemoryBound(to: sockaddr_in.self).pointee
                    var addr = sockaddrIn.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    hostStr = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            if hostStr != nil { break }
        }

        guard let host = hostStr else {
            log.warning("Could not extract IPv4 address from resolved service")
            isResolving = false
            return
        }

        let port = service.port

        // Extract token from TXT record — this is the key advantage of NetService
        // over NWBrowser, which never delivers .bonjour(txtRecord) metadata.
        var token = ""
        if let txtData = service.txtRecordData() {
            let txtDict = NetService.dictionary(fromTXTRecord: txtData)
            if let tokenData = txtDict["token"],
               let tokenStr = String(data: tokenData, encoding: .utf8) {
                token = tokenStr
            }
        }

        if token.isEmpty {
            log.info("Resolved \(service.name) at \(host):\(port) — no auth token in TXT record")
        } else {
            log.info("Resolved \(service.name) at \(host):\(port) — auth token present")
        }

        let newConfig = ScrobblerConfig(
            host: host,
            port: port,
            token: token,
            name: service.name
        )
        self.config = newConfig

        // Verify the endpoint actually responds
        Task { @MainActor in
            do {
                let reachable = try await self.getStatus()
                if reachable {
                    self.persistConfig()
                    self.isSearching = false
                    self.isResolving = false
                    self.stopDiscovery()
                    log.info("Verified scrobbler: \(service.name) at \(host):\(port)")
                } else {
                    log.warning("Resolved \(host):\(port) but status check returned false")
                    self.config = nil
                    self.isResolving = false
                }
            } catch {
                log.warning("Resolved \(host):\(port) not reachable: \(error.localizedDescription)")
                self.config = nil
                self.isResolving = false
            }
        }
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

            // Verify the cached config is still reachable; if not, auto-discover
            Task { @MainActor in
                do {
                    _ = try await getStatus()
                    log.info("Scrobbler at \(saved.host):\(saved.port) is reachable")

                    // Fetch and cache filter rules so DJ detection works immediately
                    if let filters = try? await self.getFilters() {
                        self.cacheFilterRules(filters.rules)
                    }
                } catch {
                    log.warning("Cached scrobbler at \(saved.host):\(saved.port) unreachable — auto-discovering")
                    self.config = nil
                    self.discoverScrobbler()
                }
            }
        }
    }

    // MARK: - Non-Music Filter Rules (Local Cache)

    /// Cache filter rules locally so SonosEventHandler can use them for
    /// client-side DJ/non-music detection without a server round-trip.
    func cacheFilterRules(_ rules: [FilterRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "nonMusicFilterRules")
        }
    }

    /// Load locally cached filter rules (called from SonosEventHandler).
    /// Nonisolated because UserDefaults is thread-safe and this is called
    /// from nonisolated contexts during event processing.
    nonisolated static func cachedFilterRules() -> [FilterRule] {
        guard let data = UserDefaults.standard.data(forKey: "nonMusicFilterRules"),
              let rules = try? JSONDecoder().decode([FilterRule].self, from: data) else {
            return []
        }
        return rules
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
            // Convert mode+value back to regex pattern (used by matchesNonMusicFilter)
            let escaped = NSRegularExpression.escapedPattern(for: value)
            let pattern: String
            switch mode {
            case "exact": pattern = "^\(escaped)$"
            case "starts_with": pattern = "^\(escaped)"
            case "contains": pattern = escaped
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

        guard let url = URL(string: "\(config.baseURL.absoluteString)\(path)") else {
            throw ScrobblerError.invalidResponse
        }
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

// MARK: - NetServiceBrowser Delegate

/// Delegate for NetServiceBrowser that forwards discovered services via closure.
private class BonjourBrowserDelegate: NSObject, NetServiceBrowserDelegate {
    let onFound: (NetService) -> Void

    init(onFound: @escaping (NetService) -> Void) {
        self.onFound = onFound
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        onFound(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let log = Logger(subsystem: "com.needledrop", category: "ScrobblerClient")
        log.warning("NetServiceBrowser search failed: \(errorDict)")
    }
}

// MARK: - NetService Resolve Delegate

/// Delegate for NetService resolution that delivers address + TXT record via closure.
private class BonjourResolveDelegate: NSObject, NetServiceDelegate {
    let onResolved: (NetService) -> Void
    let onError: ([String: NSNumber]) -> Void

    init(onResolved: @escaping (NetService) -> Void, onError: @escaping ([String: NSNumber]) -> Void) {
        self.onResolved = onResolved
        self.onError = onError
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        onResolved(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        onError(errorDict)
    }
}
