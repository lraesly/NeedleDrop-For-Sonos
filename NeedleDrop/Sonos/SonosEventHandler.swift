import Foundation
import Combine
import os
import SwiftUPnP

private let log = Logger(subsystem: "com.needledrop", category: "SonosEventHandler")

/// TV/HDMI audio URI prefix.
private let tvAudioURIPrefix = "x-sonos-htastream://"

/// Subscribes to AVTransport events on a Sonos group coordinator and publishes
/// now-playing state changes.
///
/// Ported from v1's `listener.py`. Handles:
/// - LastChange XML parsing → track metadata extraction
/// - Station-transition art capture (first event after station change has correct art)
/// - SiriusXM pipe format in `r:streamContent`
/// - TV audio detection (`x-sonos-htastream://`)
/// - Sonos internal string filtering
/// - Album art enrichment via iTunes Search API
@MainActor
final class SonosEventHandler: ObservableObject {

    // MARK: - Published State

    @Published var nowPlaying = NowPlayingState(transportState: .stopped)

    // MARK: - Dependencies

    let albumArtEnricher = AlbumArtEnricher()

    // MARK: - Subscription State

    private var subscribedDevice: UPnPDevice?
    private var subscribedSpeakerIP: String?
    private var avTransportService: AVTransport1Service?
    private var eventTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Station Transition Art State Machine

    /// Art URL captured from the first event after a station change.
    private var pendingArtURL: URL?
    /// Whether we're waiting for the first art after a station change.
    private var awaitingStationArt = false
    /// The last `AVTransportURI` we saw (for detecting station changes).
    private var lastAVTransportURI: String?

    // MARK: - Subscribe / Unsubscribe

    /// Subscribe to AVTransport events on a UPnP device.
    ///
    /// Finds the AVTransport service, subscribes to UPnP events, and starts
    /// listening for state changes.
    func subscribe(to device: UPnPDevice, speakerIP: String, zoneName: String) async {
        // Avoid double-subscribing to the same device
        if subscribedDevice?.uuid == device.uuid { return }

        await unsubscribe()

        log.info("Subscribing to AVTransport events on \(zoneName) (\(speakerIP))")

        // Find AVTransport1 service
        guard let service = device.services.first(where: {
            $0.serviceType == "urn:schemas-upnp-org:service:AVTransport:1"
        }) as? AVTransport1Service else {
            log.error("No AVTransport1 service found on \(zoneName)")
            return
        }

        subscribedDevice = device
        subscribedSpeakerIP = speakerIP
        avTransportService = service

        // Reset station transition state
        pendingArtURL = nil
        awaitingStationArt = false
        lastAVTransportURI = nil

        // Subscribe to UPnP events (HTTP SUBSCRIBE)
        await service.subscribeToEvents()

        // Update zone name
        nowPlaying.zoneName = zoneName

        // Listen for state changes via Combine (stays on main actor)
        service.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleEvent(state)
                }
            }
            .store(in: &cancellables)

        log.info("Subscribed to \(zoneName)")
    }

    /// Unsubscribe from the current device's events.
    func unsubscribe() async {
        cancellables.removeAll()
        eventTask?.cancel()
        eventTask = nil

        if let service = avTransportService {
            await service.unsubscribeFromEvents()
            log.info("Unsubscribed from AVTransport events")
        }

        avTransportService = nil
        subscribedDevice = nil
        subscribedSpeakerIP = nil
    }

    // MARK: - Event Handling

    /// Process a single AVTransport state change event.
    private func handleEvent(_ state: AVTransport1Service.State) async {
        guard let lastChange = state.lastChange,
              let speakerIP = subscribedSpeakerIP else { return }

        // 1. Parse the LastChange XML
        guard let event = LastChangeParser.parse(lastChange) else {
            log.debug("Could not parse LastChange XML")
            return
        }

        // 2. Detect station change
        let transportURI = event.avTransportURI ?? event.enqueuedTransportURI
        let stationChanged = event.avTransportURI != nil && event.avTransportURI != lastAVTransportURI
        if let uri = event.avTransportURI {
            lastAVTransportURI = uri
        }
        if stationChanged {
            pendingArtURL = nil
            awaitingStationArt = true
            log.debug("Station change detected")
        }

        // 3. Check for TV audio
        if let uri = transportURI, uri.hasPrefix(tvAudioURIPrefix) {
            log.info("TV audio detected")
            nowPlaying = NowPlayingState(
                track: TrackInfo(
                    title: "TV",
                    artist: "",
                    album: nil,
                    durationSeconds: 0,
                    albumArtURL: nil,
                    sourceURI: uri
                ),
                transportState: .playing,
                zoneName: nowPlaying.zoneName
            )
            return
        }

        // 4. Parse transport state
        let newTransportState: TransportState
        if let ts = event.transportState {
            newTransportState = TransportState(rawValue: ts) ?? .unknown
        } else {
            newTransportState = nowPlaying.transportState
        }

        // 5. Parse DIDL-Lite metadata
        var newArtist: String?
        var newTitle: String?
        var newAlbum: String?
        var newArtURL: URL?
        let newDuration = event.durationSeconds

        if let metaXML = event.currentTrackMetaData,
           var meta = DIDLLiteParser.parse(metaXML) {

            // Filter Sonos internal strings
            meta = meta.filtered

            newTitle = meta.title
            newArtist = meta.creator
            newAlbum = meta.album
            newArtURL = meta.resolvedAlbumArtURL(speakerIP: speakerIP)

            // Fall back to streamContent for radio
            if newArtist == nil || newTitle == nil {
                if let streamInfo = meta.parsedStreamContent {
                    if newArtist == nil { newArtist = streamInfo.artist }
                    if newTitle == nil { newTitle = streamInfo.title }
                    if newAlbum == nil { newAlbum = streamInfo.album }
                }
            }
        }

        // 6. Station-transition art capture
        if let artURL = newArtURL, awaitingStationArt, pendingArtURL == nil {
            pendingArtURL = artURL
            awaitingStationArt = false
            log.debug("Captured station-transition art: \(artURL)")
        }

        // 7. Track change detection
        if let artist = newArtist, let title = newTitle {
            let newTrackID = "\(artist)-\(title)"
            let oldTrackID = nowPlaying.track?.id

            if newTrackID != oldTrackID {
                // Use station-transition art if available (more reliable than current event's art)
                let artURL = pendingArtURL ?? newArtURL
                pendingArtURL = nil
                awaitingStationArt = false

                log.info("Track change: \(artist) — \(title)")

                // Build initial track info with Sonos art
                var track = TrackInfo(
                    title: title,
                    artist: artist,
                    album: newAlbum,
                    durationSeconds: newDuration,
                    albumArtURL: artURL,
                    sourceURI: transportURI
                )

                // Publish immediately with Sonos art
                nowPlaying = NowPlayingState(
                    track: track,
                    transportState: newTransportState,
                    zoneName: nowPlaying.zoneName
                )

                // Enrich art from iTunes in background (updates UI when done)
                Task {
                    if let enrichedURL = await albumArtEnricher.searchArt(artist: artist, title: title) {
                        // Only update if we're still on the same track
                        if self.nowPlaying.track?.id == newTrackID {
                            track.albumArtURL = enrichedURL
                            self.nowPlaying.track = track
                            log.debug("Enriched art for \(artist) — \(title)")
                        }
                    }
                }

                return
            }
        }

        // 8. Transport state change (same track, different state)
        if newTransportState != nowPlaying.transportState {
            log.debug("Transport state: \(newTransportState.rawValue)")
            nowPlaying.transportState = newTransportState
        }
    }
}
