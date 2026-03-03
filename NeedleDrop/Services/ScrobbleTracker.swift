import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.needledrop", category: "ScrobbleTracker")

/// Tracks play time locally and marks tracks as "scrobbled" when they reach
/// the threshold (50% of duration or 30s for radio with no duration).
///
/// This provides immediate scrobble badge feedback in the UI without
/// requiring a round-trip to the remote scrobbler.
@MainActor
final class ScrobbleTracker: ObservableObject {

    @Published var scrobbledTrackIds: Set<String> = []

    // MARK: - Configuration

    /// Percentage of track duration before scrobble. Default: 50%.
    var thresholdPercent: Double = 50.0
    /// Fixed minimum seconds for radio/streaming without duration. Default: 30s.
    var minSeconds: TimeInterval = 30
    /// Maximum seconds before scrobble (caps percentage-based threshold). Default: 4 min.
    var maxSeconds: TimeInterval = 240

    // MARK: - Internal State

    private var currentTrackId: String?
    private var playStartTime: Date?
    private var accumulatedPlaySeconds: TimeInterval = 0
    private var trackDuration: TimeInterval = 0
    private var scrobbleTimer: Timer?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - API

    /// Call when the now-playing state changes. Handles track changes
    /// and transport state transitions (play/pause/stop).
    func update(
        trackId: String?,
        transportState: TransportState,
        durationSeconds: Int
    ) {
        // Track change
        if trackId != currentTrackId {
            resetForNewTrack(trackId: trackId, durationSeconds: durationSeconds)
        }

        // Transport state transition
        switch transportState {
        case .playing:
            startPlaying()
        case .paused, .stopped, .transitioning, .unknown:
            pausePlaying()
        }
    }

    /// Check if a given track has been scrobbled.
    func isScrobbled(_ trackId: String) -> Bool {
        scrobbledTrackIds.contains(trackId)
    }

    /// Seed the tracker with the current playback position (from GetPositionInfo).
    /// If the position is already past the scrobble threshold, immediately mark
    /// the track as scrobbled. Handles the case where the app starts while a
    /// song is already well into playback.
    func seedPosition(_ positionSeconds: Int) {
        guard let trackId = currentTrackId else { return }
        guard !scrobbledTrackIds.contains(trackId) else { return }

        let position = TimeInterval(positionSeconds)
        if position >= threshold {
            scrobbledTrackIds.insert(trackId)
            log.info("Seeded scrobble from position: \(trackId) (position \(positionSeconds)s >= threshold \(Int(self.threshold))s)")
        }
    }

    // MARK: - Private

    private func resetForNewTrack(trackId: String?, durationSeconds: Int) {
        scrobbleTimer?.invalidate()
        scrobbleTimer = nil

        currentTrackId = trackId
        accumulatedPlaySeconds = 0
        playStartTime = nil
        trackDuration = TimeInterval(durationSeconds)

        if let trackId {
            log.debug("New track: \(trackId), duration: \(durationSeconds)s")
        }
    }

    private func startPlaying() {
        guard currentTrackId != nil else { return }
        guard !isCurrentTrackScrobbled else { return }

        playStartTime = Date()
        scheduleScrobble()
    }

    private func pausePlaying() {
        guard let start = playStartTime else { return }

        // Accumulate elapsed play time
        let elapsed = Date().timeIntervalSince(start)
        accumulatedPlaySeconds += elapsed
        playStartTime = nil

        scrobbleTimer?.invalidate()
        scrobbleTimer = nil
    }

    private var isCurrentTrackScrobbled: Bool {
        guard let id = currentTrackId else { return false }
        return scrobbledTrackIds.contains(id)
    }

    private var threshold: TimeInterval {
        if trackDuration > 0 {
            return min(trackDuration * thresholdPercent / 100.0, maxSeconds)
        } else {
            return minSeconds
        }
    }

    private func scheduleScrobble() {
        scrobbleTimer?.invalidate()

        let remaining = threshold - accumulatedPlaySeconds
        if remaining <= 0 {
            fireScrobble()
            return
        }

        scrobbleTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fireScrobble()
            }
        }
    }

    private func fireScrobble() {
        guard let trackId = currentTrackId else { return }
        guard !scrobbledTrackIds.contains(trackId) else { return }

        // Accumulate any in-flight play time
        if let start = playStartTime {
            accumulatedPlaySeconds += Date().timeIntervalSince(start)
            playStartTime = Date() // reset for continued playing
        }

        // Verify threshold met
        guard accumulatedPlaySeconds >= threshold else {
            // Re-schedule if not yet met
            scheduleScrobble()
            return
        }

        scrobbledTrackIds.insert(trackId)
        let playedSeconds = Int(self.accumulatedPlaySeconds)
        log.info("Track scrobbled: \(trackId) (played \(playedSeconds)s)")
    }
}
