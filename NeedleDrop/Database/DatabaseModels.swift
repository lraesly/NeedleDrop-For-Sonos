import Foundation
import GRDB

// MARK: - Apple Music Action Queue

struct AppleMusicActionQueueRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "apple_music_action_queue"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var createdAt: Date
    var actionType: String
    var appleMusicPersistentId: String?
    var payloadJson: String?
    var status: String
    var attemptCount: Int
    var lastAttemptedAt: Date?
    var completedAt: Date?
    var errorText: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Action Types

enum AppleMusicQueueActionType: String, Sendable {
    case incrementPlayCount = "increment_play_count"
}

enum AppleMusicQueueStatus: String, Sendable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
}
