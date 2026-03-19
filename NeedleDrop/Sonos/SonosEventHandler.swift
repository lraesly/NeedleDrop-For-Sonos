import Foundation
import Combine
import os
import SwiftUPnP

private let log = Logger(subsystem: "com.needledrop", category: "SonosEventHandler")

/// TV/HDMI audio URI prefix.
private let tvAudioURIPrefix = "x-sonos-htastream:"

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

    /// UUID of the device we're currently subscribed to (nil if not subscribed).
    /// Stripped of "uuid:" prefix to match zone coordinator UUIDs (e.g. "RINCON_xxx").
    var subscribedDeviceUUID: String? {
        subscribedDevice?.uuid.replacingOccurrences(of: "uuid:", with: "")
    }

    private var subscribedDevice: UPnPDevice?
    private var subscribedSpeakerIP: String?
    private var avTransportService: AVTransport1Service?
    private var eventTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Timestamp of the last successfully received AVTransport event.
    /// Used by AppState's position polling watchdog to detect stale subscriptions.
    private(set) var lastEventTime: Date?

    // MARK: - URLSession (no HTTP caching)

    /// Dedicated session for SOAP queries — caching disabled since responses are
    /// real-time transport state, never worth caching.
    private static let soapSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Station Transition Art State Machine

    /// Art URL captured from the first event after a station change.
    private var pendingArtURL: URL?
    /// Whether we're waiting for the first art after a station change.
    private var awaitingStationArt = false
    /// The last `AVTransportURI` we saw (for detecting station changes).
    private var lastAVTransportURI: String?
    /// Persistent station/logo art URL for the current station.
    /// Unlike `pendingArtURL` (consumed on first track change), this persists
    /// across the station session and serves as fallback art for DJ segments.
    /// `private(set)` for station break detection in position polling (AppState).
    private(set) var stationArtURL: URL?

    /// Persistent station/service name for the current station session.
    /// Set from GetMediaInfo (SOAP) and enqueuedTransportURIMetaData (events).
    /// Only cleared on actual station changes. Used as a fallback so `mediaTitle`
    /// survives race conditions between event processing and SOAP fetches.
    private var currentMediaTitle: String?

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

        // Services may not be loaded yet after SSDP discovery — retry with delay
        var service: AVTransport1Service?
        for attempt in 1...10 {
            service = device.services.first(where: {
                $0.serviceType == "urn:schemas-upnp-org:service:AVTransport:1"
            }) as? AVTransport1Service
            if service != nil { break }
            log.info("AVTransport1 not yet available on \(zoneName) (attempt \(attempt)/10), waiting...")
            try? await Task.sleep(for: .seconds(1))
        }

        guard let service else {
            log.error("No AVTransport1 service found on \(zoneName) after retries")
            return
        }

        subscribedDevice = device
        subscribedSpeakerIP = speakerIP
        avTransportService = service

        // Reset station transition state
        pendingArtURL = nil
        awaitingStationArt = false
        lastAVTransportURI = nil
        stationArtURL = nil
        currentMediaTitle = nil
        lastEventTime = Date()

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

        // Fetch current state via SOAP for immediate display. This is important
        // for TV audio and other non-streaming sources where events may not include
        // enough initial state. Events will override this when they arrive (events
        // are more authoritative for radio streams which have live streamContent).
        await fetchCurrentState(speakerIP: speakerIP)
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
        lastEventTime = nil
    }

    /// Re-subscribe to the current device's events without changing devices.
    /// Called by the position polling watchdog when the event subscription
    /// appears to have gone stale (SOAP works but no events arriving).
    func resubscribe() async {
        guard subscribedDevice != nil,
              let speakerIP = subscribedSpeakerIP else {
            log.warning("resubscribe() called with no active device")
            return
        }
        let zoneName = nowPlaying.zoneName ?? "unknown"
        log.info("Resubscribing to AVTransport events on \(zoneName) (\(speakerIP))")

        // Unsubscribe from the old subscription (clears Combine sinks)
        cancellables.removeAll()
        if let service = avTransportService {
            await service.unsubscribeFromEvents()
        }

        // Re-subscribe using the same device/service
        guard let service = avTransportService else {
            log.error("No AVTransport service for resubscribe")
            return
        }

        await service.subscribeToEvents()

        // Re-attach the Combine sink
        service.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleEvent(state)
                }
            }
            .store(in: &cancellables)

        lastEventTime = Date()  // Reset — expect a fresh event soon

        log.info("Resubscribed to \(zoneName)")

        // Refresh current state via SOAP so the display updates immediately
        await fetchCurrentState(speakerIP: speakerIP)
    }

    // MARK: - Initial State Fetch

    /// Fetch the current playing state for a zone using direct SOAP calls.
    ///
    /// Called when UPnP device isn't available yet (SSDP still running),
    /// so we can't subscribe to events but can still query via HTTP.
    func fetchInitialState(speakerIP: String, zoneName: String) async {
        nowPlaying.zoneName = zoneName
        await fetchCurrentState(speakerIP: speakerIP)
    }

    /// Fetch the current transport state and track metadata via direct SOAP calls.
    ///
    /// UPnP event subscriptions only deliver *changes*. On first subscribe we need
    /// to query GetTransportInfo + GetPositionInfo to populate the current track.
    private func fetchCurrentState(speakerIP: String) async {
        let controlURL = "http://\(speakerIP):1400/MediaRenderer/AVTransport/Control"

        // Run all SOAP queries concurrently
        async let transportResult = soapQuery(
            url: controlURL,
            action: "GetTransportInfo",
            elements: ["CurrentTransportState"]
        )
        async let positionResult = soapQuery(
            url: controlURL,
            action: "GetPositionInfo",
            elements: ["TrackMetaData", "TrackURI", "TrackDuration"]
        )
        async let mediaResult = soapQuery(
            url: controlURL,
            action: "GetMediaInfo",
            elements: ["CurrentURI", "CurrentURIMetaData"]
        )

        let transportFields = await transportResult
        let positionFields = await positionResult
        let mediaFields = await mediaResult

        let transportState = transportFields["CurrentTransportState"]
        let trackMetaData = positionFields["TrackMetaData"]
        let trackURI = positionFields["TrackURI"]
        let durationStr = positionFields["TrackDuration"]
        let enqueuedURI = mediaFields["CurrentURI"]
        let mediaMetaXML = mediaFields["CurrentURIMetaData"]

        // Parse media/station title and art from CurrentURIMetaData
        var mediaTitle: String?
        if let xml = mediaMetaXML, let mediaMeta = DIDLLiteParser.parse(xml) {
            mediaTitle = mediaMeta.title
            // Station logo art (e.g. TuneIn station image) — use as fallback
            // for DJ segments when per-track DIDL has no art
            if let mediaArt = mediaMeta.resolvedAlbumArtURL(speakerIP: speakerIP) {
                stationArtURL = mediaArt
            }
        }
        // Persist the station title so it survives race conditions
        if let mediaTitle {
            currentMediaTitle = mediaTitle
        }

        log.info("SOAP fields — transport: \(transportFields)")
        log.info("SOAP fields — position: \(positionFields.mapValues { $0.prefix(80) + ($0.count > 80 ? "…" : "") })")
        log.info("SOAP fields — media: \(mediaFields.mapValues { $0.prefix(80) + ($0.count > 80 ? "…" : "") })")
        log.info("GetMediaInfo: enqueuedURI=\(enqueuedURI ?? "nil"), mediaTitle=\(mediaTitle ?? "nil")")
        log.info("GetPositionInfo: trackURI=\(trackURI ?? "nil")")

        // Parse transport state
        let state: TransportState
        if let ts = transportState {
            state = TransportState(rawValue: ts) ?? .unknown
        } else {
            state = .unknown
        }

        // Parse duration "H:MM:SS" → seconds
        let duration = parseDuration(durationStr)

        // Check for TV audio — try TrackURI first, then CurrentURI from GetMediaInfo
        let candidateURIs = [trackURI, enqueuedURI].compactMap { $0 }
        log.info("TV check: candidates=\(candidateURIs), looking for prefix '\(tvAudioURIPrefix)'")
        let tvURI = candidateURIs.first { $0.hasPrefix(tvAudioURIPrefix) }
        if let uri = tvURI {
            nowPlaying = NowPlayingState(
                track: TrackInfo(
                    title: "TV Audio",
                    artist: "",
                    album: nil,
                    durationSeconds: 0,
                    albumArtURL: nil,
                    sourceURI: uri
                ),
                transportState: state,
                zoneName: nowPlaying.zoneName
            )
            log.info("Initial state: TV audio (\(state.rawValue))")
            return
        }

        // Parse DIDL-Lite metadata
        if let metaXML = trackMetaData,
           var meta = DIDLLiteParser.parse(metaXML) {
            meta = meta.filtered

            var artist = meta.creator
            var title = meta.title
            var album = meta.album
            let artURL = meta.resolvedAlbumArtURL(speakerIP: speakerIP)

            // For radio: streamContent has the CURRENT track info and should
            // override dc:title/dc:creator which often contain the stream/station
            // name rather than the actual song (e.g. "secretagent-128-mp3").
            var isDJ = false
            if let streamInfo = meta.parsedStreamContent {
                if let sArtist = streamInfo.artist { artist = sArtist }
                if let sTitle = streamInfo.title { title = sTitle }
                if let sAlbum = streamInfo.album { album = sAlbum }
                isDJ = streamInfo.isDJOrNonMusic
            }

            // Check configurable non-music filter rules
            if !isDJ {
                isDJ = matchesNonMusicFilter(artist: artist, title: title)
            }

            if let artist, let title {
                var track = TrackInfo(
                    title: title,
                    artist: artist,
                    album: album,
                    durationSeconds: duration,
                    albumArtURL: artURL ?? stationArtURL,
                    sourceURI: trackURI,
                    isDJSegment: isDJ
                )

                nowPlaying = NowPlayingState(
                    track: track,
                    transportState: state,
                    zoneName: nowPlaying.zoneName,
                    enqueuedURI: enqueuedURI,
                    mediaTitle: mediaTitle
                )

                // Seed station state so the first event doesn't trigger a
                // false station-change and so DJ segments have fallback art.
                if let uri = enqueuedURI {
                    lastAVTransportURI = uri
                }
                if let artURL {
                    stationArtURL = artURL
                }

                log.info("Initial state: \(artist) — \(title) (\(state.rawValue)), media=\(mediaTitle ?? "nil")")

                // Enrich art from iTunes (duration skipped for initial fetch —
                // we can't determine position within a radio song mid-stream,
                // so the progress bar waits until the next event-driven track change)
                Task {
                    let enrichment = await albumArtEnricher.searchArt(artist: artist, title: title)
                    guard self.nowPlaying.track?.id == track.id else { return }

                    if let url = enrichment?.artURL {
                        track.albumArtURL = url
                    }
                    // Fall back to station logo when no art was found
                    if track.albumArtURL == nil, let fallback = self.stationArtURL {
                        track.albumArtURL = fallback
                    }
                    self.nowPlaying.track = track
                }
                return
            }
        }

        // No track metadata — check if this is a radio station (playing, paused,
        // or transitioning but no song metadata). Show the station name so the UI
        // isn't blank. STOPPED = paused for streaming radio (SiriusXM, TuneIn).
        if let stationName = mediaTitle ?? currentMediaTitle {
            log.info("Initial state: station \(stationName) (\(state.rawValue))")

            // Seed station state for subsequent events
            if let uri = enqueuedURI {
                lastAVTransportURI = uri
            }

            nowPlaying = NowPlayingState(
                track: TrackInfo(
                    title: stationName,
                    artist: "",
                    album: nil,
                    durationSeconds: 0,
                    albumArtURL: stationArtURL,
                    sourceURI: trackURI,
                    isDJSegment: true
                ),
                transportState: state,
                zoneName: nowPlaying.zoneName,
                enqueuedURI: enqueuedURI,
                mediaTitle: stationName
            )
            return
        }

        // No track metadata and not a station break — just update transport state
        nowPlaying = NowPlayingState(
            track: nil,
            transportState: state,
            zoneName: nowPlaying.zoneName
        )
        log.info("Initial state: no track (\(state.rawValue))")
    }

    /// Send a SOAP query and extract multiple elements from the response.
    private nonisolated func soapQuery(url: String, action: String, elements: [String]) async -> [String: String] {
        guard let url = URL(string: url) else { return [:] }

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 5

        do {
            let (data, response) = try await Self.soapSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [:] }

            let parser = SOAPMultiElementExtractor(data: data, targetElements: Set(elements))
            return parser.extract()
        } catch {
            return [:]
        }
    }

    /// Check if a track matches any locally cached non-music filter rules.
    ///
    /// The same rules are also used server-side by the Python scrobbler.
    /// Patterns are matched as case-insensitive regex (same as the server).
    private nonisolated func matchesNonMusicFilter(artist: String?, title: String?) -> Bool {
        let rules = ScrobblerClient.cachedFilterRules()
        guard !rules.isEmpty else { return false }
        for rule in rules {
            guard !rule.pattern.isEmpty else { continue }
            let target: String?
            switch rule.type {
            case .artistExclude: target = artist
            case .titleExclude:  target = title
            }
            guard let target, !target.isEmpty else { continue }
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive) {
                let range = NSRange(target.startIndex..., in: target)
                if regex.firstMatch(in: target, range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Parse "H:MM:SS" or "0:MM:SS" duration string to seconds.
    private nonisolated func parseDuration(_ str: String?) -> Int {
        guard let str, !str.isEmpty, str != "NOT_IMPLEMENTED" else { return 0 }
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    // MARK: - Event Handling

    /// Process a single AVTransport state change event.
    private func handleEvent(_ state: AVTransport1Service.State) async {
        guard let lastChange = state.lastChange,
              let speakerIP = subscribedSpeakerIP else {
            return
        }

        lastEventTime = Date()

        // 1. Parse the LastChange XML
        guard let event = LastChangeParser.parse(lastChange) else {
            log.debug("Could not parse LastChange XML")
            return
        }

        // 1b. Log all events for diagnostics
        log.info("AVTransport event: transportState=\(event.transportState ?? "nil"), hasTrackMeta=\(event.currentTrackMetaData != nil), avTransportURI=\(event.avTransportURI?.prefix(80) ?? "nil")")

        // 2. Detect station change
        //    Only trigger when we had a previous URI (lastAVTransportURI != nil).
        //    The first event after subscribe() has lastAVTransportURI == nil — that's
        //    not a station change, just the initial state arriving via events.
        let transportURI = event.avTransportURI ?? event.enqueuedTransportURI
        let stationChanged = event.avTransportURI != nil
            && lastAVTransportURI != nil
            && event.avTransportURI != lastAVTransportURI
        if let uri = event.avTransportURI {
            lastAVTransportURI = uri
        }
        if stationChanged {
            pendingArtURL = nil
            stationArtURL = nil
            currentMediaTitle = nil
            awaitingStationArt = true
            // Clear stale media title immediately — the new station's title will
            // arrive in a subsequent event's enqueuedTransportURIMetaData.
            nowPlaying.mediaTitle = nil
            log.debug("Station change detected — cleared mediaTitle")
        }

        // 2b. Update media title and station art from enqueued metadata (station/favorite name).
        //     Only write to @Published nowPlaying when the value actually changes
        //     to avoid unnecessary SwiftUI redraws (SiriusXM sends frequent events).
        if let metaXML = event.enqueuedTransportURIMetaData,
           let meta = DIDLLiteParser.parse(metaXML) {
            if let title = meta.title {
                currentMediaTitle = title
                if nowPlaying.mediaTitle != title {
                    nowPlaying.mediaTitle = title
                    log.debug("Media title from event: \(title)")
                }
            }
            // Station logo art from enqueued metadata (e.g. TuneIn station image)
            if stationArtURL == nil,
               let mediaArt = meta.resolvedAlbumArtURL(speakerIP: speakerIP) {
                stationArtURL = mediaArt
                log.debug("Station art from enqueued metadata: \(mediaArt)")
            }
        }

        // 2c. Update enqueued URI from event (only on change)
        if let enqueued = event.enqueuedTransportURI,
           enqueued != nowPlaying.enqueuedURI {
            nowPlaying.enqueuedURI = enqueued
            log.debug("Enqueued URI from event: \(enqueued)")
        }

        // 3. Check for TV audio
        if let uri = transportURI, uri.hasPrefix(tvAudioURIPrefix) {
            // Use actual transport state from event, fall back to current state
            let tvState: TransportState
            if let ts = event.transportState {
                tvState = TransportState(rawValue: ts) ?? nowPlaying.transportState
            } else {
                tvState = nowPlaying.transportState
            }
            log.info("TV audio detected (\(tvState.rawValue))")
            nowPlaying = NowPlayingState(
                track: TrackInfo(
                    title: "TV Audio",
                    artist: "",
                    album: nil,
                    durationSeconds: 0,
                    albumArtURL: nil,
                    sourceURI: uri
                ),
                transportState: tvState,
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
        var isDJSegment = false

        if let metaXML = event.currentTrackMetaData,
           var meta = DIDLLiteParser.parse(metaXML) {

            // Filter Sonos internal strings
            meta = meta.filtered

            newTitle = meta.title
            newArtist = meta.creator
            newAlbum = meta.album
            newArtURL = meta.resolvedAlbumArtURL(speakerIP: speakerIP)

            // Log raw radio metadata for diagnostics
            log.info("Event DIDL: title=\(meta.title ?? "nil"), creator=\(meta.creator ?? "nil"), streamContent=\(meta.streamContent ?? "nil"), radioShowMd=\(meta.radioShowMd ?? "nil")")

            // For radio: streamContent has the CURRENT track info and should
            // override dc:title/dc:creator which often contain the stream/station
            // name rather than the actual song (e.g. "secretagent-128-mp3").
            if let streamInfo = meta.parsedStreamContent {
                if let artist = streamInfo.artist { newArtist = artist }
                if let title = streamInfo.title { newTitle = title }
                if let album = streamInfo.album { newAlbum = album }
                isDJSegment = streamInfo.isDJOrNonMusic
            }
        }

        // Check configurable non-music filter rules (from Settings → Scrobbling)
        if !isDJSegment {
            isDJSegment = matchesNonMusicFilter(artist: newArtist, title: newTitle)
        }

        // 6. Station-transition art capture
        if let artURL = newArtURL, awaitingStationArt, pendingArtURL == nil {
            pendingArtURL = artURL
            stationArtURL = artURL // Persist for DJ segment fallback
            awaitingStationArt = false
            log.debug("Captured station-transition art: \(artURL)")
        }

        // 7. Track change detection
        // For radio/DJ segments, artist may be nil — treat as empty string
        let resolvedTitle = newTitle
        let resolvedArtist = newArtist ?? (resolvedTitle != nil ? "" : nil)

        if let title = resolvedTitle, let artist = resolvedArtist {
            let newTrackID = "\(artist)-\(title)"
            let oldTrackID = nowPlaying.track?.id

            if newTrackID != oldTrackID {
                // Use station-transition art if available (more reliable than current event's art).
                // For DJ segments, fall back to persistent station art (logo).
                let artURL = pendingArtURL ?? newArtURL ?? stationArtURL
                pendingArtURL = nil
                awaitingStationArt = false

                if isDJSegment {
                    log.info("DJ segment: \(artist) — \(title)")
                } else {
                    log.info("Track change: \(artist) — \(title)")
                }

                // Build initial track info with Sonos art
                var track = TrackInfo(
                    title: title,
                    artist: artist,
                    album: newAlbum,
                    durationSeconds: newDuration,
                    albumArtURL: artURL,
                    sourceURI: transportURI,
                    isDJSegment: isDJSegment
                )

                // Publish immediately with Sonos art
                // Carry forward media title: prefer event metadata, then current
                // nowPlaying value, then the persistent station title as fallback.
                var updatedMediaTitle = nowPlaying.mediaTitle ?? currentMediaTitle
                if let metaXML = event.enqueuedTransportURIMetaData,
                   let meta = DIDLLiteParser.parse(metaXML),
                   let mTitle = meta.title {
                    currentMediaTitle = mTitle
                    updatedMediaTitle = mTitle
                }
                nowPlaying = NowPlayingState(
                    track: track,
                    transportState: newTransportState,
                    zoneName: nowPlaying.zoneName,
                    enqueuedURI: event.enqueuedTransportURI ?? nowPlaying.enqueuedURI,
                    mediaTitle: updatedMediaTitle
                )

                // Enrich art + duration from iTunes in background (only for actual songs with artist)
                if !artist.isEmpty, !isDJSegment {
                    Task {
                        let enrichment = await albumArtEnricher.searchArt(artist: artist, title: title)
                        // Only update if we're still on the same track
                        guard self.nowPlaying.track?.id == newTrackID else { return }

                        if let url = enrichment?.artURL {
                            track.albumArtURL = url
                        }
                        if let dur = enrichment?.durationSeconds, track.durationSeconds == 0 {
                            track.durationSeconds = dur
                            log.debug("Enriched duration for \(artist) — \(title): \(dur)s")
                        }
                        // Fall back to station logo when no art was found
                        // (iTunes miss + no per-track art in DIDL)
                        if track.albumArtURL == nil, let fallback = self.stationArtURL {
                            track.albumArtURL = fallback
                        }
                        self.nowPlaying.track = track
                    }
                }

                return
            }
        }

        // 7b. Radio station break detection: when a radio stream event arrives
        //     with metadata but no artist/title/streamContent, the song has ended
        //     and a DJ/break segment is in progress. Clear the track and show the
        //     station name. This is generic for TuneIn and similar radio providers.
        if resolvedTitle == nil,
           event.currentTrackMetaData != nil,
           let stationName = nowPlaying.mediaTitle ?? currentMediaTitle {
            log.info("Station break detected on \(stationName)")
            nowPlaying = NowPlayingState(
                track: TrackInfo(
                    title: stationName,
                    artist: "",
                    album: nil,
                    durationSeconds: 0,
                    albumArtURL: stationArtURL,
                    sourceURI: transportURI,
                    isDJSegment: true
                ),
                transportState: newTransportState,
                zoneName: nowPlaying.zoneName,
                enqueuedURI: nowPlaying.enqueuedURI,
                mediaTitle: stationName
            )
            return
        }

        // 8. Between-song transition art: show station art when track metadata
        //    disappears (e.g., SomaFM DJ segments between songs). The art from
        //    the event is the station logo — swap it in so the UI visually signals
        //    the transition. Track info stays the same (no banner/scrobble).
        if resolvedTitle == nil,
           let artURL = newArtURL,
           var track = nowPlaying.track,
           artURL != track.albumArtURL {
            track.albumArtURL = artURL
            nowPlaying.track = track
            log.debug("Transition art: \(artURL)")
        }

        // 9. Transport state change (same track, different state)
        if newTransportState != nowPlaying.transportState {
            log.debug("Transport state: \(newTransportState.rawValue)")
            nowPlaying.transportState = newTransportState
        }
    }
}

// MARK: - SOAP Multi-Element Extractor

/// Generic XML parser that extracts text content of multiple named elements
/// from a SOAP response envelope.
private class SOAPMultiElementExtractor: NSObject, XMLParserDelegate {
    private let data: Data
    private let targetElements: Set<String>
    private var currentElement = ""
    private var currentText = ""
    private var extractedValues: [String: String] = [:]

    init(data: Data, targetElements: Set<String>) {
        self.data = data
        self.targetElements = targetElements
    }

    func extract() -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return extractedValues
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = element
        if targetElements.contains(element) {
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if targetElements.contains(currentElement) {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if targetElements.contains(element) && extractedValues[element] == nil {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                extractedValues[element] = text
            }
        }
    }
}
