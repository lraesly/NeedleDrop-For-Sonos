import Foundation

struct Preset: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var favorite: PresetFavorite
    var rooms: [String]
    var coordinatorRoom: String
    var volume: Int?

    init(id: UUID = UUID(), name: String, favorite: PresetFavorite, rooms: [String], coordinatorRoom: String, volume: Int? = nil) {
        self.id = id
        self.name = name
        self.favorite = favorite
        self.rooms = rooms
        self.coordinatorRoom = coordinatorRoom
        self.volume = volume
    }
}

struct PresetFavorite: Codable, Equatable, Hashable {
    let title: String
    let uri: String
    let meta: String
    let albumArtUri: String?
}
