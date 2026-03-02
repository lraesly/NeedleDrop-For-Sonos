import Foundation

/// A single scrobble filter rule.
struct FilterRule: Codable, Equatable, Identifiable {
    let id: UUID
    var pattern: String
    var type: FilterType

    enum FilterType: String, Codable {
        case artistExclude = "artist_exclude"
        case titleExclude = "title_exclude"
    }

    init(id: UUID = UUID(), pattern: String, type: FilterType) {
        self.id = id
        self.pattern = pattern
        self.type = type
    }
}
