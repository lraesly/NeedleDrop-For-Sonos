import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.needledrop", category: "PlaySession")

/// Manages the lifecycle of play sessions: open on track start, accumulate
/// duration during playback, close on track change / stop / sleep.
///
/// Determines qualified plays and enqueues Apple Music play count increments.
/// Session state is held in memory only — no longer persisted to SQLite.
///
/// Called from AppState's nowPlaying sink alongside ScrobbleTracker.
@MainActor
final class PlaySessionManager {
    private let queueRepo: AppleMusicActionQueueRepository

    // Active session state (in-memory only)
    private var activeTrackId: String?
    private var activeRawTitle: String?
    private var activeRawArtist: String?
    private var activeRawDurationMs: Int?
    private var activeSourceService: String?
    private var activeTrackInLibrary: Bool = false
    private var lastPlayingTime: Date?
    private var accumulatedMs: Int = 0

    init(dbPool: DatabasePool) {
        self.queueRepo = AppleMusicActionQueueRepository(dbPool: dbPool)
    }

    // MARK: - State Change Handler

    /// Called from AppState's nowPlaying sink on every state change.
    /// Mirrors the ScrobbleTracker.update() call pattern.
    /// - Parameter isTrackInLibrary: whether the current track is in the user's Apple Music library
    ///   (used to gate play count enqueue — only enqueue if the track is known to be in the library).
    func onStateChange(
        trackId: String?,
        track: TrackInfo?,
        transportState: TransportState,
        householdId: String?,
        isTrackInLibrary: Bool = false
    ) {
        let isDJ = track?.isDJSegment == true
        let isTV = track?.isTVAudio == true

        // Update library status for the active session (the async library check
        // in AppState may complete after the session was opened).
        if trackId == activeTrackId, isTrackInLibrary {
            activeTrackInLibrary = true
        }

        // Don't track DJ segments or TV audio
        guard !isDJ, !isTV else {
            if activeTrackId != nil {
                closeActiveSession(reason: "track_change")
            }
            return
        }

        // Track change — close previous session, open new one
        if trackId != activeTrackId {
            if activeTrackId != nil {
                closeActiveSession(reason: "track_change")
            }

            if let track, let trackId, !trackId.isEmpty {
                openSession(track: track)
            }
        }

        // Transport state transition
        switch transportState {
        case .playing:
            startAccumulating()
        case .paused:
            pauseAccumulating()
        case .stopped:
            pauseAccumulating()
            if activeTrackId != nil {
                closeActiveSession(reason: "stopped")
            }
        case .transitioning, .unknown:
            break
        }
    }

    // MARK: - Close Active Session (public for sleep/wake)

    /// Close the currently active session with the given reason.
    /// Safe to call when no session is active (no-op).
    func closeActiveSession(reason: String) {
        guard activeTrackId != nil else { return }

        // Accumulate any in-flight play time
        if let start = lastPlayingTime {
            accumulatedMs += Int(Date().timeIntervalSince(start) * 1000)
            lastPlayingTime = nil
        }

        let durationMs = activeRawDurationMs ?? 0
        let qualified = Self.isQualifiedPlay(playedMs: accumulatedMs, durationMs: durationMs)

        let playedSec = accumulatedMs / 1000
        log.info("Closed session: \(playedSec)s played, qualified=\(qualified), reason=\(reason)")

        // Enqueue Apple Music play count increment if qualified AND track is in library.
        // Skip when source is Apple Music — Music.app already increments its own play count.
        let isAppleMusicSource = activeSourceService == "apple_music"
        if qualified, activeTrackInLibrary, !isAppleMusicSource,
           let title = activeRawTitle, let artist = activeRawArtist {
            enqueuePlayCountIfNeeded(title: title, artist: artist)
        }

        activeTrackId = nil
        activeRawTitle = nil
        activeRawArtist = nil
        activeRawDurationMs = nil
        activeSourceService = nil
        activeTrackInLibrary = false
        accumulatedMs = 0
        lastPlayingTime = nil
    }

    // MARK: - Private

    private func openSession(track: TrackInfo) {
        activeTrackId = track.id
        activeRawTitle = track.title
        activeRawArtist = track.artist
        activeRawDurationMs = track.durationSeconds > 0 ? track.durationSeconds * 1000 : nil
        activeSourceService = Self.classifySourceService(uri: track.sourceURI)
        accumulatedMs = 0
        lastPlayingTime = nil

        log.info("Opened session: \(track.artist) — \(track.title)")
    }

    private func startAccumulating() {
        guard activeTrackId != nil, lastPlayingTime == nil else { return }
        lastPlayingTime = Date()
    }

    private func pauseAccumulating() {
        guard let start = lastPlayingTime else { return }
        accumulatedMs += Int(Date().timeIntervalSince(start) * 1000)
        lastPlayingTime = nil
    }

    // MARK: - Apple Music Queue

    private func enqueuePlayCountIfNeeded(title: String, artist: String) {
        do {
            try queueRepo.enqueue(
                actionType: .incrementPlayCount,
                rawTitle: title,
                rawArtist: artist
            )
        } catch {
            log.error("Failed to enqueue play count: \(error.localizedDescription)")
        }
    }

    // MARK: - Qualified Play

    /// Same threshold rules as ScrobbleTracker:
    /// - 50% of duration, or 30s minimum for radio/no-duration, capped at 4 minutes
    static func isQualifiedPlay(playedMs: Int, durationMs: Int) -> Bool {
        let playedSec = Double(playedMs) / 1000.0
        let durationSec = Double(durationMs) / 1000.0
        let threshold: Double
        if durationSec > 0 {
            threshold = min(durationSec * 0.5, 240.0)
        } else {
            threshold = 30.0
        }
        return playedSec >= threshold
    }

    // MARK: - Source Classification

    /// Classify the playback source from the Sonos URI.
    static func classifySourceService(uri: String?) -> String? {
        guard let uri else { return nil }
        if uri.contains("x-sonos-http") && uri.contains("apple") { return "apple_music" }
        if uri.contains("x-sonos-spotify") || uri.contains("spotify") { return "spotify" }
        if uri.contains("x-sonosapi-hls-static") || uri.contains("siriusxm") { return "siriusxm" }
        if uri.contains("x-sonosapi-stream") || uri.contains("x-rincon-mp3radio") { return "radio" }
        if uri.contains("x-file-cifs") || uri.contains("x-smb") { return "local_library" }
        return "unknown"
    }
}
