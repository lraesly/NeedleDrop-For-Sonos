import Foundation

/// The current playback state for a zone.
struct NowPlayingState: Equatable {
    var track: TrackInfo?
    var transportState: TransportState
    var zoneName: String?
}

/// Transport state of a Sonos zone.
enum TransportState: String, Equatable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case unknown = "UNKNOWN"
}

/// Information about the currently playing track.
struct TrackInfo: Equatable, Identifiable {
    let title: String
    let artist: String
    let album: String?
    let durationSeconds: Int
    var albumArtURL: URL?
    let sourceURI: String?

    /// Unique identifier for dedup and save tracking.
    var id: String { "\(artist)-\(title)" }

    /// Whether the source is TV/HDMI audio.
    var isTVAudio: Bool {
        sourceURI?.hasPrefix("x-sonos-htastream://") == true
    }
}
