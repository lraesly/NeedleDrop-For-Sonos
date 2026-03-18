import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.needledrop", category: "AMActionQueue")

/// CRUD operations for the apple_music_action_queue table.
struct AppleMusicActionQueueRepository: Sendable {
    let dbPool: DatabasePool

    /// Enqueue a new Apple Music action.
    @discardableResult
    func enqueue(
        actionType: AppleMusicQueueActionType,
        rawTitle: String,
        rawArtist: String
    ) throws -> AppleMusicActionQueueRecord {
        let payload = try JSONEncoder().encode(
            ["raw_title": rawTitle, "raw_artist": rawArtist]
        )

        var record = AppleMusicActionQueueRecord(
            createdAt: Date(),
            actionType: actionType.rawValue,
            appleMusicPersistentId: nil,
            payloadJson: String(data: payload, encoding: .utf8),
            status: AppleMusicQueueStatus.pending.rawValue,
            attemptCount: 0,
            lastAttemptedAt: nil,
            completedAt: nil,
            errorText: nil
        )

        try dbPool.write { db in
            try record.insert(db)
        }

        log.info("Enqueued \(actionType.rawValue) for \(rawArtist) — \(rawTitle)")
        return record
    }

    /// Fetch pending items that haven't exceeded max retries.
    func fetchPending(limit: Int = 20, maxAttempts: Int = 3) throws -> [AppleMusicActionQueueRecord] {
        try dbPool.read { db in
            try AppleMusicActionQueueRecord
                .filter(Column("status") == AppleMusicQueueStatus.pending.rawValue)
                .filter(Column("attempt_count") < maxAttempts)
                .order(Column("created_at"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Update a queue item (after processing attempt).
    func update(_ record: AppleMusicActionQueueRecord) throws {
        try dbPool.write { db in
            try record.update(db)
        }
    }

    /// Count of pending items.
    func pendingCount() throws -> Int {
        try dbPool.read { db in
            try AppleMusicActionQueueRecord
                .filter(Column("status") == AppleMusicQueueStatus.pending.rawValue)
                .fetchCount(db)
        }
    }
}
