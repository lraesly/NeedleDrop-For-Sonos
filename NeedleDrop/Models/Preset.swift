import Foundation

struct Preset: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var favorite: PresetFavorite
    var rooms: [String]
    var coordinatorRoom: String
    var volume: Int?
    /// Sonos household ID that owns this preset.  `nil` = legacy/untagged (shown everywhere).
    var householdId: String?

    init(id: UUID = UUID(), name: String, favorite: PresetFavorite, rooms: [String], coordinatorRoom: String, volume: Int? = nil, householdId: String? = nil) {
        self.id = id
        self.name = name
        self.favorite = favorite
        self.rooms = rooms
        self.coordinatorRoom = coordinatorRoom
        self.volume = volume
        self.householdId = householdId
    }
}

struct PresetFavorite: Codable, Equatable, Hashable {
    let title: String
    let uri: String
    let meta: String
    let albumArtUri: String?
}
