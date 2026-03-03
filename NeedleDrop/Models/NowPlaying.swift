import Foundation

/// The current playback state for a zone.
struct NowPlayingState: Equatable {
    var track: TrackInfo?
    var transportState: TransportState
    var zoneName: String?

    /// The enqueued transport URI (container/favorite URI for radio/streaming).
    /// Closer to the Sonos favorite URI than `track.sourceURI` which may be a
    /// transient stream URL.
    var enqueuedURI: String?

    /// The media/station title from GetMediaInfo metadata (e.g., "Underground Garage").
    /// Used as a fallback when URI matching fails for preset auto-population.
    var mediaTitle: String?
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
    var durationSeconds: Int
    var albumArtURL: URL?
    let sourceURI: String?

    /// Whether this is a non-music segment (SiriusXM DJ talk, ad break, etc.).
    /// When true, the track should not be scrobbled, should not trigger banners,
    /// and the heart button should be hidden.
    var isDJSegment: Bool = false

    /// Unique identifier for dedup and save tracking.
    var id: String { "\(artist)-\(title)" }

    /// Whether the source is TV/HDMI audio.
    var isTVAudio: Bool {
        sourceURI?.hasPrefix("x-sonos-htastream:") == true
    }
}
