import Foundation
import SwiftUPnP

/// Represents a Sonos speaker discovered on the local network.
struct SonosDevice: Identifiable, Equatable, Codable {
    let uuid: String          // RINCON_XXXXXXXXXXXX
    let roomName: String      // e.g. "Living Room"
    let ip: String            // e.g. "192.168.1.10"
    var isCoordinator: Bool   // true if this speaker is the group coordinator
    var groupId: String?      // shared among grouped speakers

    var id: String { uuid }

    /// Base URL for SOAP control and device description.
    var baseURL: URL {
        URL(string: "http://\(ip):1400")!
    }

    /// URL for the device description XML.
    var deviceDescriptionURL: URL {
        baseURL.appendingPathComponent("/xml/device_description.xml")
    }
}

/// Represents a Sonos zone group (a coordinator + its grouped members).
struct SonosZoneGroup: Identifiable, Equatable {
    let coordinator: SonosDevice
    let members: [SonosDevice]

    var id: String { coordinator.uuid }
    var roomName: String { coordinator.roomName }

    /// Order-independent equality: Sonos may return members in different order
    /// between topology polls. Without this, `@Published var zones` would fire
    /// `objectWillChange` on every poll, causing unnecessary SwiftUI redraws.
    static func == (lhs: SonosZoneGroup, rhs: SonosZoneGroup) -> Bool {
        lhs.coordinator == rhs.coordinator
            && Set(lhs.members.map(\.uuid)) == Set(rhs.members.map(\.uuid))
    }
}
