import Foundation

/// A Sonos Favorite item (station, playlist, track, etc.).
struct FavoriteItem: Identifiable, Equatable, Hashable {
    let title: String
    let uri: String
    let meta: String
    let albumArtUri: String?

    var id: String { uri }
}
