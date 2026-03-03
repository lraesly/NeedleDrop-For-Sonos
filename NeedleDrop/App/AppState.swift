import SwiftUI
import Combine
import os
import SwiftUPnP

private let log = Logger(subsystem: "com.needledrop", category: "AppState")

/// Connection state of the app to Sonos speakers.
enum ConnectionState: Equatable {
    case disconnected
    case discovering
    case connected
    case error(String)
}

/// Mini player layout mode.
enum MiniPlayerSize: String {
    case compact   // 300×120, 56×56 art
    case large     // 400×320, 200×200 art
}

/// Central app state — coordinates Sonos discovery, events, and UI.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Connection

    @Published var connectionState: ConnectionState = .disconnected

    // MARK: - Sonos

    @Published var nowPlaying = NowPlayingState(transportState: .stopped)
    @Published var speakers: [SonosDevice] = []
    @Published var zones: [SonosZoneGroup] = []
    @Published var selectedZone: String?
    @Published var volume: Int = 0
    @Published var favorites: [FavoriteItem] = []

    // MARK: - Presets

    let presetStore = PresetStore()
    @Published var presetNav: PresetNav?

    // MARK: - Library

    let spotifyService = SpotifyService()
    let appleMusicService = AppleMusicService()
    @Published var lastSaveResult: LibrarySaveDetail?
    /// Track IDs that have been successfully saved this session.
    @Published var savedTrackIds: Set<String> = []
    /// Track ID currently being saved (for in-progress heart animation).
    @Published var savingTrackId: String?

    // MARK: - Playback Position

    /// Current playback position in seconds (updated by polling).
    @Published var playbackPosition: Int = 0
    /// Track duration in seconds from GetPositionInfo (updated by polling).
    @Published var playbackDuration: Int = 0
    private var positionPollingTask: Task<Void, Never>?

    /// Local elapsed counter for radio/streaming tracks where GetPositionInfo
    /// returns duration 0 but event metadata has the track duration.
    private var radioPosition: Int = 0
    /// Track ID for the current radio position counter (resets on track change).
    private var radioPositionTrackId: String?
    /// Whether the radio counter has been seeded from SOAP for the current track.
    /// On app restart mid-song, SOAP RelTime may hold a valid per-track position
    /// that lets us resume roughly where the song actually is.
    private var radioPositionSeeded = false

    // MARK: - Scrobbler

    let scrobblerClient = ScrobblerClient()
    let scrobbleTracker = ScrobbleTracker()

    // MARK: - Mini Player

    @Published var isMiniPlayerVisible = false
    @Published var isMiniPlayerActive = false
    @Published var miniPlayerFlashCount = 0

    /// Persisted: transparent overlay vs solid background for the mini player.
    var isMiniPlayerTransparent: Bool {
        get { UserDefaults.standard.object(forKey: "isMiniPlayerTransparent") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "isMiniPlayerTransparent")
            Task { @MainActor in self.objectWillChange.send() }
        }
    }

    /// Persisted: compact or large mini player layout.
    var miniPlayerSize: MiniPlayerSize {
        get {
            if let raw = UserDefaults.standard.string(forKey: "miniPlayerSize"),
               let size = MiniPlayerSize(rawValue: raw) {
                return size
            }
            return .compact
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "miniPlayerSize")
            Task { @MainActor in self.objectWillChange.send() }
            // Defer resize to next run-loop tick to avoid publishing during view update
            let size = newValue
            Task { @MainActor [weak self] in
                self?.miniPlayerWindow.resize(for: size)
            }
        }
    }

    /// Persisted: whether the mini player opens automatically on app launch.
    var launchMiniPlayerOnStart: Bool {
        get { UserDefaults.standard.bool(forKey: "launchMiniPlayerOnStart") }
        set {
            UserDefaults.standard.set(newValue, forKey: "launchMiniPlayerOnStart")
            Task { @MainActor in self.objectWillChange.send() }
        }
    }

    let miniPlayerWindow = MiniPlayerWindow()
    let albumArtWindow = AlbumArtWindow()

    // MARK: - Banner

    /// Persisted: whether track-change banners are enabled.
    var isBannerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isBannerEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "isBannerEnabled")
            Task { @MainActor in self.objectWillChange.send() }
        }
    }

    // MARK: - Default Zone

    /// Persisted: preferred zone name. nil = auto (follow first available).
    var defaultZone: String? {
        get { UserDefaults.standard.string(forKey: "defaultZone") }
        set {
            UserDefaults.standard.set(newValue, forKey: "defaultZone")
            Task { @MainActor in self.objectWillChange.send() }
        }
    }
    let bannerWindow = BannerWindow()
    private var bannerDismissTask: Task<Void, Never>?

    // MARK: - Menu Bar

    var menuBarIcon: String {
        connectionState == .connected ? "MenuBarIcon" : "MenuBarIconDisconnected"
    }

    // MARK: - Services

    let speakerStore = SpeakerStore()
    lazy var discoveryService = SonosDiscoveryService(speakerStore: speakerStore)
    let eventHandler = SonosEventHandler()
    let controller = SonosController()
    let zoneManager = SonosZoneManager()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - App Nap Prevention

    /// Activity token that prevents App Nap from suspending the process.
    /// UPnP event subscriptions and the HTTP callback server need to stay alive.
    nonisolated(unsafe) private var appNapActivity: NSObjectProtocol?

    // MARK: - Sleep/Wake

    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?

    /// Volume level saved before mute, used for unmuting.
    private var preMuteVolume: Int?

    // MARK: - Init

    init() {
        setupBindings()
        startDiscovery()
        scrobblerClient.loadPersistedConfig()
        preventAppNap()
        setupSleepWakeObservers()

        if launchMiniPlayerOnStart {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.miniPlayerWindow.show(appState: self)
                self.isMiniPlayerVisible = true
            }
        }
    }

    deinit {
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        if let o = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    // MARK: - App Nap Prevention

    private func preventAppNap() {
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "UPnP event listener and HTTP callback server"
        )
        log.info("App Nap prevention enabled")
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            log.info("System sleep — unsubscribing from events, clearing caches")
            guard let self else { return }
            Task { @MainActor in
                await self.eventHandler.unsubscribe()
                // Clear session-level caches to reclaim memory during sleep
                self.scrobbleTracker.scrobbledTrackIds.removeAll()
                self.savedTrackIds.removeAll()
                await self.eventHandler.albumArtEnricher.clearCache()
                ImageCache.shared.clearAll()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            log.info("System wake — re-subscribing to events")
            guard let self else { return }
            Task { @MainActor in
                // Re-subscribe to the active zone's events after a brief delay
                // to let the network come back up
                try? await Task.sleep(for: .seconds(2))
                self.resubscribeToActiveZone()
            }
        }
    }

    /// Re-subscribe to AVTransport events for the active zone.
    /// Called after sleep/wake or network change.
    private func resubscribeToActiveZone() {
        guard let zone = activeZone else { return }

        if let upnpDevice = discoveryService.upnpDevice(for: zone.coordinator.uuid) {
            Task {
                await eventHandler.subscribe(
                    to: upnpDevice,
                    speakerIP: zone.coordinator.ip,
                    zoneName: zone.roomName
                )
                refreshVolume()
            }
        } else {
            // UPnP device lost after sleep — reload directly.
            // trySubscribeToActiveZone will handle subscription when ready.
            discoveryService.loadUPnPDeviceDirectly(
                ip: zone.coordinator.ip,
                uuid: zone.coordinator.uuid
            )
        }
    }

    // MARK: - Discovery

    private func startDiscovery() {
        connectionState = .discovering
        discoveryService.startDiscovery()
    }

    private func setupBindings() {
        // Mirror discovered speakers to app state
        discoveryService.$speakers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speakers in
                guard let self else { return }
                self.speakers = speakers
                if !speakers.isEmpty && self.connectionState != .connected {
                    self.connectionState = .connected
                    log.info("Connected — found \(speakers.count) speaker(s)")

                    // Load zones, favorites, and subscribe to events
                    self.onConnected()
                }

                // When new UPnP devices are discovered via SSDP, try to subscribe
                // to the active zone if we haven't yet (e.g., zone was selected
                // before SSDP finished discovering the device)
                self.trySubscribeToActiveZone()
            }
            .store(in: &cancellables)

        // Mirror event handler's now-playing state to app state,
        // feed scrobble tracker, and trigger banner/mini-player updates
        eventHandler.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nowPlaying in
                guard let self else { return }
                let oldTrackId = self.nowPlaying.track?.id
                self.nowPlaying = nowPlaying

                let isDJ = nowPlaying.track?.isDJSegment == true

                // Feed scrobble tracker (skip DJ segments — don't scrobble talk/ads)
                if !isDJ {
                    self.scrobbleTracker.update(
                        trackId: nowPlaying.track?.id,
                        transportState: nowPlaying.transportState,
                        durationSeconds: nowPlaying.track?.durationSeconds ?? 0
                    )
                }

                // Detect track change for banner + mini player flash (skip DJ segments)
                if let track = nowPlaying.track,
                   !track.isTVAudio,
                   !track.isDJSegment,
                   track.id != oldTrackId {
                    self.onTrackChange(track: track)
                }

                // Keep mini player title in sync
                self.miniPlayerWindow.updateTitle(for: nowPlaying.track, mediaTitle: nowPlaying.mediaTitle)

                // Start/stop position polling based on transport state
                let isPlaying = nowPlaying.transportState == .playing
                let isTV = nowPlaying.track?.isTVAudio == true
                if isPlaying && !isTV {
                    self.startPositionPolling()
                } else {
                    self.stopPositionPolling()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Track Change Handling

    /// Called when a new track starts playing. Shows banner and flashes mini player.
    private func onTrackChange(track: TrackInfo) {
        log.info("Track change: \(track.artist) — \(track.title)")

        // Flash the mini player (triggers song-change reveal in transparent mode)
        miniPlayerFlashCount += 1

        // Show banner notification if enabled
        if isBannerEnabled {
            showBanner(track: track)
        }

        // Check if track is already in the active music library (background, non-blocking)
        if !track.artist.isEmpty {
            if spotifyService.isConnected {
                spotifyService.loadLibraryIfNeeded()
                Task {
                    let inLibrary = await spotifyService.isInLibrary(
                        title: track.title, artist: track.artist
                    )
                    if inLibrary {
                        log.info("Track in Spotify library: \(track.artist) — \(track.title)")
                        self.savedTrackIds.insert(track.id)
                    }
                }
            } else if appleMusicService.isConnected {
                Task {
                    let inLibrary = await appleMusicService.isInLibrary(
                        title: track.title, artist: track.artist
                    )
                    if inLibrary {
                        log.info("Track in Apple Music library: \(track.artist) — \(track.title)")
                        self.savedTrackIds.insert(track.id)
                    }
                }
            }
        }
    }

    // MARK: - Banner

    private func showBanner(track: TrackInfo) {
        // Cancel any pending dismiss
        bannerDismissTask?.cancel()

        bannerWindow.showBanner(track: track, appState: self)

        // Auto-dismiss after 4 seconds
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            bannerWindow.dismissBanner()
        }
    }

    // MARK: - Mini Player

    func toggleMiniPlayer() {
        if isMiniPlayerVisible {
            miniPlayerWindow.dismiss()
            isMiniPlayerVisible = false
            isMiniPlayerActive = false
        } else {
            miniPlayerWindow.show(appState: self)
            isMiniPlayerVisible = true
        }
    }

    // MARK: - Connection Setup

    /// Called once when speakers are first discovered. Loads zone topology,
    /// favorites, and subscribes to the active zone's events.
    private func onConnected() {
        guard let firstSpeaker = speakers.first else { return }

        Task {
            // Fetch zone topology
            let groups = await zoneManager.getZoneGroups(speakerIP: firstSpeaker.ip)
            self.zones = groups

            // Auto-select zone:
            // 1. Find the zone that is currently PLAYING
            // 2. Fall back to persisted default zone
            // 3. Fall back to first zone
            if selectedZone == nil {
                var playingZone: SonosZoneGroup?

                // Poll each coordinator's transport state concurrently
                await withTaskGroup(of: (String, String?).self) { taskGroup in
                    for group in groups {
                        taskGroup.addTask {
                            let state = await self.zoneManager.getTransportState(
                                speakerIP: group.coordinator.ip
                            )
                            return (group.coordinator.uuid, state)
                        }
                    }

                    for await (uuid, state) in taskGroup {
                        if state == "PLAYING" {
                            playingZone = groups.first(where: { $0.coordinator.uuid == uuid })
                            log.info("Found playing zone: \(playingZone?.roomName ?? "?")")
                        }
                    }
                }

                if let zone = playingZone {
                    selectZone(zone.coordinator.uuid)
                } else if let defaultName = defaultZone,
                          let match = groups.first(where: { $0.roomName == defaultName }) {
                    selectZone(match.coordinator.uuid)
                } else if let first = groups.first {
                    selectZone(first.coordinator.uuid)
                }
            }

            // Fetch favorites from the coordinator (raw SOAP, no UPnP device needed)
            if let zone = activeZone {
                let favs = await zoneManager.getFavorites(speakerIP: zone.coordinator.ip)
                self.favorites = favs
            }
        }
    }

    // MARK: - Zone Selection

    /// The currently selected zone group.
    var activeZone: SonosZoneGroup? {
        zones.first(where: { $0.coordinator.uuid == selectedZone })
    }

    /// Select a zone to control. Subscribes to its coordinator's events.
    func selectZone(_ coordinatorUUID: String) {
        guard coordinatorUUID != selectedZone else { return }
        selectedZone = coordinatorUUID

        guard let zone = activeZone else { return }
        log.info("Selected zone: \(zone.roomName)")

        // Clear stale now-playing from the previous zone immediately
        nowPlaying = NowPlayingState(transportState: .stopped, zoneName: zone.roomName)
        isTVMuted = false
        stopPositionPolling()

        // Subscribe to the coordinator's AVTransport events
        if let upnpDevice = discoveryService.upnpDevice(for: zone.coordinator.uuid) {
            Task {
                await eventHandler.subscribe(
                    to: upnpDevice,
                    speakerIP: zone.coordinator.ip,
                    zoneName: zone.roomName
                )
                refreshVolume()
            }
        } else {
            // UPnP device not yet discovered via SSDP — two-pronged approach:
            // 1. Fetch initial state via direct SOAP (fast, just needs IP)
            // 2. Load UPnP device directly from device description XML (bypasses SSDP).
            //    When loaded, trySubscribeToActiveZone will auto-subscribe to events.
            log.info("UPnP device not yet available for \(zone.roomName), fetching state via SOAP + loading UPnP device directly")
            Task {
                await eventHandler.fetchInitialState(
                    speakerIP: zone.coordinator.ip,
                    zoneName: zone.roomName
                )
            }
            discoveryService.loadUPnPDeviceDirectly(
                ip: zone.coordinator.ip,
                uuid: zone.coordinator.uuid
            )
        }
    }

    /// Try to subscribe to the active zone's events if not already subscribed.
    /// Called when new UPnP devices are discovered via SSDP.
    private func trySubscribeToActiveZone() {
        guard let zone = activeZone,
              eventHandler.subscribedDeviceUUID != zone.coordinator.uuid,
              let upnpDevice = discoveryService.upnpDevice(for: zone.coordinator.uuid) else {
            return
        }

        log.info("UPnP device now available for \(zone.roomName) — subscribing to events")
        Task {
            await eventHandler.subscribe(
                to: upnpDevice,
                speakerIP: zone.coordinator.ip,
                zoneName: zone.roomName
            )
            refreshVolume()

            // Fetch favorites if not yet loaded (deferred from onConnected)
            if favorites.isEmpty {
                let favs = await zoneManager.getFavorites(speakerIP: zone.coordinator.ip)
                if !favs.isEmpty {
                    log.info("Loaded \(favs.count) favorites (deferred)")
                    self.favorites = favs
                }
            }
        }
    }

    // MARK: - Active Device

    /// The UPnP device for the active zone's coordinator.
    /// All control commands target this device.
    private var activeUPnPDevice: UPnPDevice? {
        if let zone = activeZone {
            return discoveryService.upnpDevice(for: zone.coordinator.uuid)
        }
        // Fallback to first speaker if no zone selected yet
        guard let speaker = speakers.first else { return nil }
        return discoveryService.upnpDevice(for: speaker.uuid)
    }

    // MARK: - Playback Controls

    /// Whether TV audio is currently muted via the play/pause toggle.
    /// Sonos ignores Pause and Stop for HDMI streams, so we use mute/unmute instead.
    @Published var isTVMuted = false

    func togglePlayPause() {
        guard let device = activeUPnPDevice else { return }
        let isTV = nowPlaying.track?.isTVAudio == true
        Task {
            if isTV {
                // TV audio is a live HDMI stream — Pause/Stop are ignored by Sonos.
                // Use mute/unmute instead and toggle the icon locally.
                isTVMuted.toggle()
                await controller.setMute(device: device, muted: isTVMuted)
            } else if nowPlaying.transportState == .playing {
                await controller.pause(device: device)
            } else {
                await controller.play(device: device)
            }
        }
    }

    func nextTrack() {
        guard let device = activeUPnPDevice else { return }
        Task {
            await controller.next(device: device)
        }
    }

    func previousTrack() {
        guard let device = activeUPnPDevice else { return }
        Task {
            await controller.previous(device: device)
        }
    }

    func setVolume(_ level: Int) {
        guard let device = activeUPnPDevice else { return }
        volume = level
        Task {
            await controller.setVolume(device: device, level: level)
        }
    }

    /// Toggle mute: if volume > 0, store it and set to 0. Otherwise restore.
    func toggleMute() {
        if volume > 0 {
            preMuteVolume = volume
            setVolume(0)
        } else if let saved = preMuteVolume {
            setVolume(saved)
            preMuteVolume = nil
        } else {
            setVolume(20) // reasonable default
        }
    }

    func playFavorite(_ favorite: FavoriteItem) {
        guard let device = activeUPnPDevice else { return }
        log.info("Playing favorite: \(favorite.title)")

        // Clear stale media title immediately so the UI doesn't show the
        // previous station's name while the new one loads.
        nowPlaying.mediaTitle = nil
        eventHandler.nowPlaying.mediaTitle = nil
        miniPlayerWindow.updateTitle(for: nowPlaying.track, mediaTitle: nil)

        Task {
            await controller.playURI(
                device: device,
                uri: favorite.uri,
                metadata: favorite.meta
            )
        }
    }

    // MARK: - Speaker Grouping

    /// Join a speaker to the active zone's coordinator.
    func joinSpeaker(_ speakerUUID: String) {
        guard let zone = activeZone else { return }
        // Find the speaker's IP from zone topology (works even without SSDP discovery)
        guard let speaker = allTopologySpeakers.first(where: { $0.uuid == speakerUUID }) else {
            log.warning("Speaker \(speakerUUID) not found in zone topology")
            return
        }
        Task {
            await zoneManager.joinSpeaker(
                speakerIP: speaker.ip,
                toCoordinatorUUID: zone.coordinator.uuid
            )
            // Refresh zones after grouping change
            await refreshZones()
        }
    }

    /// All visible speakers from zone topology (coordinators + members from all zones).
    /// Unlike `speakers` (SSDP discovery), this always includes all speakers on the network.
    var allTopologySpeakers: [SonosDevice] {
        zones.flatMap { zone in
            [zone.coordinator] + zone.members
        }
    }

    /// Remove a speaker from its group.
    func unjoinSpeaker(_ speaker: SonosDevice) {
        Task {
            await zoneManager.unjoinSpeaker(speakerIP: speaker.ip)
            // Refresh zones after grouping change
            await refreshZones()
        }
    }

    /// Refresh zone topology from the network.
    func refreshZones() async {
        guard let firstSpeaker = speakers.first else { return }
        let groups = await zoneManager.getZoneGroups(speakerIP: firstSpeaker.ip)
        self.zones = groups
    }

    // MARK: - Volume Polling

    /// Fetch the current volume from the active device.
    func refreshVolume() {
        guard let device = activeUPnPDevice else { return }
        Task {
            if let vol = await controller.getVolume(device: device) {
                self.volume = vol
            }
        }
    }

    // MARK: - Position Polling

    /// Start polling GetPositionInfo every second while playing.
    ///
    /// For standard tracks, SOAP returns both position and duration.
    /// For radio/streaming (SiriusXM, SomaFM), SOAP returns duration 0 but the
    /// event metadata has the track duration — in that case, use a local elapsed
    /// counter for position.
    private func startPositionPolling() {
        guard positionPollingTask == nil else { return }
        log.debug("Starting position polling")
        positionPollingTask = Task { @MainActor [weak self] in
            var seededPosition = false
            while !Task.isCancelled {
                guard let self else { break }

                let trackDuration = self.nowPlaying.track?.durationSeconds ?? 0
                let currentTrackId = self.nowPlaying.track?.id

                // Reset local radio counter on track change
                if currentTrackId != self.radioPositionTrackId {
                    self.radioPosition = 0
                    self.radioPositionTrackId = currentTrackId
                    self.radioPositionSeeded = false
                }

                // Device may be temporarily nil during SSDP re-discovery — keep retrying
                if let device = self.activeUPnPDevice,
                   let info = await self.controller.getPositionInfo(device: device) {
                    if info.duration > 0 {
                        // Standard track — SOAP has both position and duration
                        self.playbackPosition = info.position
                        self.playbackDuration = info.duration

                        // On first poll, seed the scrobble tracker with current position.
                        // Handles the case where the app starts mid-song.
                        if !seededPosition {
                            seededPosition = true
                            self.scrobbleTracker.seedPosition(info.position)
                        }
                    } else if trackDuration > 0 {
                        // Radio/streaming — SOAP duration is 0, use local counter.
                        // On first entry, try to seed from SOAP position (useful on
                        // app restart mid-song). If SOAP position exceeds the track
                        // duration it's stale/cumulative — ignore and start at 0.
                        if !self.radioPositionSeeded {
                            self.radioPositionSeeded = true
                            if info.position > 0, info.position < trackDuration {
                                self.radioPosition = info.position
                            }
                        } else {
                            self.radioPosition += 1
                        }
                        self.playbackPosition = min(self.radioPosition, trackDuration)
                        self.playbackDuration = trackDuration
                    } else {
                        // No duration yet. For non-TV tracks (e.g. radio waiting
                        // for iTunes enrichment), keep the previous progress bar
                        // visible rather than flashing it away between songs.
                        if self.nowPlaying.track == nil || self.nowPlaying.track?.isTVAudio == true {
                            self.playbackPosition = 0
                            self.playbackDuration = 0
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stop position polling and reset values.
    private func stopPositionPolling() {
        guard positionPollingTask != nil else { return }
        log.debug("Stopping position polling")
        positionPollingTask?.cancel()
        positionPollingTask = nil
        playbackPosition = 0
        playbackDuration = 0
    }

    // MARK: - Presets

    /// Activate a preset: group rooms, set volume, play favorite.
    func activatePreset(_ preset: Preset) {
        log.info("Activating preset: \(preset.name)")

        // Clear stale media title immediately so the UI doesn't show the
        // previous station's name while the new one loads.
        nowPlaying.mediaTitle = nil
        eventHandler.nowPlaying.mediaTitle = nil
        miniPlayerWindow.updateTitle(for: nowPlaying.track, mediaTitle: nil)

        Task {
            // 1. Find the coordinator by room name
            guard let coordinatorSpeaker = speakers.first(where: { $0.roomName == preset.coordinatorRoom }) else {
                log.error("Coordinator room '\(preset.coordinatorRoom)' not found")
                return
            }

            // 2. Group/ungroup rooms as needed
            for roomName in preset.rooms {
                if roomName == preset.coordinatorRoom { continue }
                if let speaker = allTopologySpeakers.first(where: { $0.roomName == roomName }) ?? speakers.first(where: { $0.roomName == roomName }) {
                    await zoneManager.joinSpeaker(
                        speakerIP: speaker.ip,
                        toCoordinatorUUID: coordinatorSpeaker.uuid
                    )
                }
            }

            // 3. Set volume before playing (so it doesn't blast at previous level)
            if let vol = preset.volume,
               let device = discoveryService.upnpDevice(for: coordinatorSpeaker.uuid) {
                await controller.setVolume(device: device, level: vol)
                self.volume = vol
            }

            // 4. Play the favorite
            if let device = discoveryService.upnpDevice(for: coordinatorSpeaker.uuid) {
                await controller.playURI(
                    device: device,
                    uri: preset.favorite.uri,
                    metadata: preset.favorite.meta
                )
            }

            // 5. Switch active zone to the preset's coordinator
            selectZone(coordinatorSpeaker.uuid)

            // 6. Refresh zones to reflect new grouping
            await refreshZones()
        }
    }

    // MARK: - Library Saves

    /// Whether the heart/save button should be shown (at least one service connected).
    var canSaveToLibrary: Bool {
        spotifyService.isConnected || appleMusicService.isConnected
    }

    /// Save the current track to the active music library (Spotify or Apple Music).
    func saveToLibrary() {
        guard let track = nowPlaying.track else { return }
        log.info("Saving to library: \(track.artist) – \(track.title)")

        savingTrackId = track.id

        Task {
            let result: ServiceSaveResult
            if spotifyService.isConnected {
                result = await spotifyService.searchAndSave(title: track.title, artist: track.artist)
            } else if appleMusicService.isConnected {
                result = await appleMusicService.searchAndSave(title: track.title, artist: track.artist)
            } else {
                self.savingTrackId = nil
                return
            }

            let detail = LibrarySaveDetail(
                trackId: track.id,
                results: [result]
            )
            self.lastSaveResult = detail
            self.savingTrackId = nil

            if result.success {
                self.savedTrackIds.insert(track.id)
            }
        }
    }
}

/// Navigation state for preset editing views.
enum PresetNav: Equatable {
    case list
    case create
    case edit(Preset)
    case createFromCurrent(rooms: [String], coordinatorRoom: String, sourceUri: String?)
}
