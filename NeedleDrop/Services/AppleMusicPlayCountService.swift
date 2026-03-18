import Foundation
import GRDB
import AppKit
import os

private let log = Logger(subsystem: "com.needledrop", category: "AMPlayCount")

/// Result of looking up a track's persistent ID in Music.app.
private enum PersistentIdLookupResult {
    case found(String)
    case notFound
    case timeout
}

/// Drains the Apple Music action queue by executing AppleScript commands
/// to increment play counts in Music.app.
///
/// Only processes the queue when Music.app is already running (no auto-launch).
/// Runs on a 60-second timer while the app is active.
@MainActor
final class AppleMusicPlayCountService {
    private let dbPool: DatabasePool
    private let queueRepo: AppleMusicActionQueueRepository
    private var drainTimer: Timer?

    /// Whether Apple Music play count sync is enabled by the user.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "appleMusicPlayCountEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "appleMusicPlayCountEnabled") }
    }

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.queueRepo = AppleMusicActionQueueRepository(dbPool: dbPool)
    }

    /// Start the periodic queue drain timer (every 60 seconds).
    func startDraining() {
        guard drainTimer == nil else { return }
        drainTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.drainQueue()
            }
        }
        log.info("Apple Music action queue drain timer started")

        // Also drain once on startup (after a short delay for app init)
        Task {
            try? await Task.sleep(for: .seconds(5))
            await drainQueue()
        }
    }

    /// Stop the drain timer.
    func stopDraining() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    // MARK: - Queue Drain

    private func drainQueue() async {
        guard isEnabled else { return }

        // Only process if Music.app is already running
        guard isMusicAppRunning() else {
            log.debug("Music.app not running — skipping queue drain")
            return
        }

        let items: [AppleMusicActionQueueRecord]
        do {
            items = try queueRepo.fetchPending(limit: 20, maxAttempts: 3)
        } catch {
            log.error("Failed to fetch pending queue items: \(error.localizedDescription)")
            return
        }

        guard !items.isEmpty else { return }
        log.info("Draining \(items.count) pending Apple Music action(s)")

        for var item in items {
            // Mark as processing
            item.status = AppleMusicQueueStatus.processing.rawValue
            item.attemptCount += 1
            item.lastAttemptedAt = Date()
            try? queueRepo.update(item)

            switch item.actionType {
            case AppleMusicQueueActionType.incrementPlayCount.rawValue:
                await processPlayCountIncrement(&item)
            default:
                item.status = AppleMusicQueueStatus.failed.rawValue
                item.errorText = "Unknown action type: \(item.actionType)"
                try? queueRepo.update(item)
            }
        }
    }

    private func processPlayCountIncrement(_ item: inout AppleMusicActionQueueRecord) async {
        // Get title/artist from payload
        guard let payloadJson = item.payloadJson,
              let payloadData = payloadJson.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: String].self, from: payloadData),
              let title = payload["raw_title"],
              let artist = payload["raw_artist"] else {
            item.status = AppleMusicQueueStatus.failed.rawValue
            item.errorText = "Missing title/artist in payload"
            try? queueRepo.update(item)
            return
        }

        // Step 1: Look up persistent ID (if we don't already have it)
        var persistentId = item.appleMusicPersistentId
        if persistentId == nil {
            let lookupResult = await lookupPersistentId(title: title, artist: artist)
            switch lookupResult {
            case .found(let id):
                persistentId = id
                item.appleMusicPersistentId = id
            case .notFound:
                if item.attemptCount >= 3 {
                    item.status = AppleMusicQueueStatus.failed.rawValue
                    item.errorText = "Track not found in Music.app library: \(artist) — \(title)"
                } else {
                    item.status = AppleMusicQueueStatus.pending.rawValue
                }
                try? queueRepo.update(item)
                log.warning("Persistent ID lookup failed for \(artist) — \(title)")
                return
            case .timeout:
                // Don't count timeouts against the attempt limit — re-queue for retry
                item.attemptCount -= 1
                item.status = AppleMusicQueueStatus.pending.rawValue
                try? queueRepo.update(item)
                log.warning("Persistent ID lookup timed out for \(artist) — \(title), will retry")
                return
            }
        }

        guard let persistentId else { return }

        // Step 2: Increment play count
        let success = await incrementPlayCount(persistentId: persistentId)

        if success {
            item.status = AppleMusicQueueStatus.completed.rawValue
            item.completedAt = Date()
            log.info("Incremented play count for \(artist) — \(title) (pid: \(persistentId))")
        } else if item.attemptCount >= 3 {
            item.status = AppleMusicQueueStatus.failed.rawValue
            item.errorText = "AppleScript execution failed after \(item.attemptCount) attempts"
        } else {
            item.status = AppleMusicQueueStatus.pending.rawValue // retry later
        }

        try? queueRepo.update(item)
    }

    // MARK: - AppleScript Execution

    /// Look up the persistent ID of a track in Music.app by title and artist.
    private func lookupPersistentId(title: String, artist: String) async -> PersistentIdLookupResult {
        let escapedTitle = title.escapedForAppleScript
        let escapedArtist = artist.escapedForAppleScript

        let script = """
        tell application "Music"
            set matchingTracks to (every track of library playlist 1 \u{00AC}
                whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
            if (count of matchingTracks) > 0 then
                return persistent ID of item 1 of matchingTracks
            else
                return ""
            end if
        end tell
        """

        let result = await runAppleScriptWithTimeout(script, seconds: 5)
        guard let resultString = result else { return .timeout }
        if resultString.isEmpty { return .notFound }
        return .found(resultString)
    }

    /// Increment the play count and update the last played date for a track.
    private func incrementPlayCount(persistentId: String) async -> Bool {
        let script = """
        tell application "Music"
            set theTrack to (first track of library playlist 1 \u{00AC}
                whose persistent ID is "\(persistentId)")
            set played count of theTrack to (played count of theTrack) + 1
            set played date of theTrack to current date
            return "ok"
        end tell
        """

        let result = await runAppleScriptWithTimeout(script, seconds: 5)
        return result == "ok"
    }

    /// Run an AppleScript off the main thread with a timeout.
    private func runAppleScriptWithTimeout(_ source: String, seconds: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                // Run AppleScript off main thread (it blocks the calling thread)
                let result: String? = await Task.detached {
                    let appleScript = NSAppleScript(source: source)
                    var error: NSDictionary?
                    let descriptor = appleScript?.executeAndReturnError(&error)
                    if let error {
                        let log = Logger(subsystem: "com.needledrop", category: "AMPlayCount")
                        log.warning("AppleScript error: \(error)")
                        return nil
                    }
                    return descriptor?.stringValue
                }.value
                return result
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }

            // Return whichever finishes first
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    private func isMusicAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music"
        ).isEmpty
    }
}

// MARK: - String Extension for AppleScript

private extension String {
    /// Escape a string for safe inclusion in AppleScript double-quoted strings.
    var escapedForAppleScript: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
