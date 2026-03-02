import Foundation

/// Configuration for connecting to the remote NeedleDrop scrobbler.
struct ScrobblerConfig: Codable, Equatable, Identifiable {
    let host: String
    let port: Int
    let token: String
    let name: String

    var id: String { "\(host):\(port)" }

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}
