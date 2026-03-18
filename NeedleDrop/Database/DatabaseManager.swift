import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.needledrop", category: "Database")

/// Manages the SQLite database connection pool and schema migrations.
/// Thread-safe — DatabasePool handles concurrent reads and serialized writes.
final class DatabaseManager: Sendable {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private init() {
        do {
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let dbDir = appSupportURL.appendingPathComponent("com.needledrop")
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbPath = dbDir.appendingPathComponent("needledrop.sqlite").path

            var config = Configuration()
            config.foreignKeysEnabled = true

            dbPool = try DatabasePool(path: dbPath, configuration: config)
            try Self.runMigrations(dbPool)
            log.info("Database opened at \(dbPath)")
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    private static func runMigrations(_ dbPool: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "household") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("household_id", .text).notNull().unique()
                t.column("display_name", .text)
                t.column("timezone", .text)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "zone") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("household_id", .text).notNull()
                t.column("sonos_zone_uuid", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "play_session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("household_id", .text).notNull()
                t.column("zone_id", .integer).notNull().references("zone", onDelete: .restrict)
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("raw_title", .text).notNull()
                t.column("raw_artist", .text).notNull()
                t.column("raw_album", .text)
                t.column("raw_duration_ms", .integer)
                t.column("source_service", .text)
                t.column("source_uri", .text)
                t.column("apple_music_catalog_id", .text)
                t.column("apple_music_persistent_id", .text)
                t.column("played_duration_ms", .integer).notNull().defaults(to: 0)
                t.column("completion_percent", .double)
                t.column("qualified_play", .boolean).notNull().defaults(to: false)
                t.column("transport_end_reason", .text)
                t.column("raw_payload_json", .text)
                t.column("inserted_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_play_session_started_at", on: "play_session", columns: ["started_at"])
            try db.create(index: "idx_play_session_raw_artist_title", on: "play_session", columns: ["raw_artist", "raw_title"])
            try db.create(index: "idx_play_session_qualified", on: "play_session", columns: ["qualified_play"])

            try db.create(table: "user_action") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("occurred_at", .datetime).notNull()
                t.column("play_session_id", .integer).references("play_session", onDelete: .setNull)
                t.column("action_type", .text).notNull()
                t.column("raw_title", .text).notNull()
                t.column("raw_artist", .text).notNull()
                t.column("success", .boolean)
                t.column("metadata_json", .text)
                t.column("inserted_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_user_action_play_session", on: "user_action", columns: ["play_session_id"])
            try db.create(index: "idx_user_action_action_type", on: "user_action", columns: ["action_type"])

            try db.create(table: "apple_music_action_queue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("action_type", .text).notNull()
                t.column("play_session_id", .integer).references("play_session", onDelete: .setNull)
                t.column("apple_music_persistent_id", .text)
                t.column("payload_json", .text)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("last_attempted_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("error_text", .text)
            }
            try db.create(index: "idx_amaq_status", on: "apple_music_action_queue", columns: ["status"])
        }

        migrator.registerMigration("v2_remove_play_logging") { db in
            // Drop tables that reference play_session first
            try db.drop(table: "user_action")

            // Recreate apple_music_action_queue without play_session_id FK
            try db.create(table: "apple_music_action_queue_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("action_type", .text).notNull()
                t.column("apple_music_persistent_id", .text)
                t.column("payload_json", .text)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("last_attempted_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("error_text", .text)
            }
            try db.execute(sql: """
                INSERT INTO apple_music_action_queue_new
                    (id, created_at, action_type, apple_music_persistent_id,
                     payload_json, status, attempt_count, last_attempted_at,
                     completed_at, error_text)
                SELECT id, created_at, action_type, apple_music_persistent_id,
                       payload_json, status, attempt_count, last_attempted_at,
                       completed_at, error_text
                FROM apple_music_action_queue
                """)
            try db.drop(table: "apple_music_action_queue")
            try db.rename(table: "apple_music_action_queue_new", to: "apple_music_action_queue")
            try db.create(index: "idx_amaq_status", on: "apple_music_action_queue", columns: ["status"])

            // Drop play logging tables
            try db.drop(table: "play_session")
            try db.drop(table: "zone")
            try db.drop(table: "household")

            log.info("Removed play session logging tables (v2 migration)")
        }

        try migrator.migrate(dbPool)
    }
}
