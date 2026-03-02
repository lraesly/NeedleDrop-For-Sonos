import Foundation

/// Configuration for connecting to the remote NeedleDrop scrobbler.
struct ScrobblerConfig: Codable, Equatable, Identifiable {
    let host: String
    let port: Int
    let token: String
    let name: String

    var id: String { "\(host):\(port)" }

    var baseURL: URL {
        // Wrap IPv6 addresses in brackets for valid URL construction
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(hostPart):\(port)")!
    }
}
