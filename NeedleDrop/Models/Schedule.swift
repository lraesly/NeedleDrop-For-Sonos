import Foundation

/// A recurring playback schedule managed by the server.
/// The client creates/edits these; the server executes them on time.
struct PlaybackSchedule: Codable, Identifiable, Equatable {
    let id: String               // UUID from server
    var name: String
    var enabled: Bool

    // What to play
    var favoriteTitle: String?
    var favoriteUri: String
    var favoriteMeta: String?

    // Where to play
    var rooms: [String]?
    var coordinatorRoom: String?
    var volume: Int?

    // When to play
    var startTime: String        // "07:30" (24h local)
    var stopTime: String?        // "09:00" or nil
    var days: [Int]              // [0,1,2,3,4] Mon=0..Sun=6

    // Housekeeping
    var householdId: String?
    var lastTriggeredAt: String?
    var createdAt: String?
    var updatedAt: String?

    /// Day-of-week labels for display.
    static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Human-readable schedule summary (e.g. "Mon–Fri 07:30–09:00").
    var summary: String {
        let dayStr: String
        if days.sorted() == [0, 1, 2, 3, 4] {
            dayStr = "Weekdays"
        } else if days.sorted() == [5, 6] {
            dayStr = "Weekends"
        } else if days.sorted() == [0, 1, 2, 3, 4, 5, 6] {
            dayStr = "Every day"
        } else {
            dayStr = days.sorted().map { Self.dayLabels[$0] }.joined(separator: ", ")
        }

        if let stop = stopTime {
            return "\(dayStr) \(startTime)–\(stop)"
        }
        return "\(dayStr) \(startTime)"
    }

    // Server uses snake_case JSON keys
    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case favoriteTitle = "favorite_title"
        case favoriteUri = "favorite_uri"
        case favoriteMeta = "favorite_meta"
        case rooms
        case coordinatorRoom = "coordinator_room"
        case volume
        case startTime = "start_time"
        case stopTime = "stop_time"
        case days
        case householdId = "household_id"
        case lastTriggeredAt = "last_triggered_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Create a schedule from an existing preset with time parameters.
    static func fromPreset(_ preset: Preset, startTime: String, stopTime: String?, days: [Int]) -> PlaybackSchedule {
        PlaybackSchedule(
            id: UUID().uuidString,
            name: preset.name,
            enabled: true,
            favoriteTitle: preset.favorite.title,
            favoriteUri: preset.favorite.uri,
            favoriteMeta: preset.favorite.meta,
            rooms: preset.rooms,
            coordinatorRoom: preset.coordinatorRoom,
            volume: preset.volume,
            startTime: startTime,
            stopTime: stopTime,
            days: days,
            householdId: preset.householdId
        )
    }
}
