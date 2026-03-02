import Foundation

/// Information about a Sonos zone (group) for UI display.
struct ZoneInfo: Identifiable, Equatable {
    let name: String
    let uuid: String
    let ip: String
    let members: [String]      // room names of grouped speakers
    let transportState: String

    var id: String { uuid }
}

/// Information about an individual Sonos speaker for UI display.
struct SpeakerInfo: Identifiable, Equatable {
    let name: String
    let uuid: String
    let ip: String
    let coordinatorName: String
    let isCoordinator: Bool

    var id: String { uuid }
}
