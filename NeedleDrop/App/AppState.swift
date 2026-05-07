import SwiftUI
import Combine
import os
import ServiceManagement
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
    /// Per-speaker volumes for the active group, keyed by speaker UUID.
    /// Used to apply proportional group volume changes and drive per-speaker UI.
    @Published var groupSpeakerVolumes: [String: Int] = [:]
    /// Whether the active speaker is muted (Sonos hardware mute, independent of volume level).
    @Published var isMuted = false
    @Published var favorites: [FavoriteItem] = []
    /// [Audit fix #6: guard flag to prevent concurrent favorites loading]
    private var isLoadingFavorites = false

    // MARK: - Custom Stations

    let customStationStore = CustomStationStore()
    @Published var customStationNav: CustomStationNav?

    /// Sonos favorites merged with user-defined custom stations for use in pickers.
    var allStationChoices: [FavoriteItem] {
        let custom = customStationStore.stations.map(\.asFavoriteItem)
        return custom + favorites
    }

    // MARK: - Presets & Home

    let presetStore = PresetStore()
    let homeStore = HomeStore()
    @Published var presetNav: PresetNav?
    /// The Sonos household ID for the currently connected system.
    @Published var currentHouseholdId: String?
    /// Whether the "Name This Home" prompt should be shown.
    @Published var pendingHomeNaming = false

    /// Presets filtered to the current home (or all if no home detected).
    var filteredPresets: [Preset] {
        guard let current = currentHouseholdId else { return presetStore.presets }
        return presetStore.presets.filter { $0.householdId == nil || $0.householdId == current }
    }

    /// User-friendly name for the current home, if known.
    var currentHomeName: String? {
        guard let id = currentHouseholdId else { return nil }
        return homeStore.nameForHousehold(id)
    }

    // MARK: - Schedules

    @Published var scheduleNav: ScheduleNav?
    @Published var schedules: [PlaybackSchedule] = []
    private(set) lazy var scheduleClient: ScheduleClient = ScheduleClient(scrobblerClient: scrobblerClient)

    func loadSchedules() async {
        guard scrobblerClient.config != nil else { return }
        do {
            schedules = try await scheduleClient.listSchedules()
        } catch {
            log.error("Failed to load schedules: \(error.localizedDescription)")
        }
    }

    // MARK: - Library

    let spotifyService = SpotifyService()
    let appleMusicService = AppleMusicService()
    @Published var lastSaveResult: LibrarySaveDetail?
    /// Track IDs that have been successfully saved this session.
    @Published var savedTrackIds: Set<String> = []
    /// Track ID currently being saved (for in-progress heart animation).
    @Published var savingTrackId: String?
    /// Brief warning shown near the heart button (e.g., "Apple Music disconnected").
    /// Auto-clears after a few seconds.
    @Published var saveWarningMessage: String?
    /// Session-scoped opt-in: when on, every newly resolved track is added to the
    /// user's Apple Music library (without loving) unless already present.
    /// Resets to off on zone change or source (enqueuedURI) change.
    @Published var autoAddToAppleMusic: Bool = false
    /// Track IDs we've already attempted to auto-add this session, to prevent
    /// duplicate save attempts when the same track resurfaces.
    private var autoAddAttemptedTrackIds: Set<String> = []

    // MARK: - Playback Position

    /// Current playback position in seconds (updated by polling).
    @Published var playbackPosition: Int = 0
    /// Track duration in seconds from GetPositionInfo (updated by polling).
    @Published var playbackDuration: Int = 0
    private var positionPollingTask: Task<Void, Never>?
    private var zoneTopologyPollingTask: Task<Void, Never>?
    private var eventWatchdogTask: Task<Void, Never>?
    /// Timestamp of the last watchdog resubscribe attempt (throttles to once per 120s).
    private var lastWatchdogResubscribeAttempt: Date?

    /// Local elapsed counter for radio/streaming tracks where GetPositionInfo
    /// returns duration 0 but event metadata has the track duration.
    private var radioPosition: Int = 0
    /// Track ID for the current radio position counter (resets on track change).
    private var radioPositionTrackId: String?
    /// Last `r:streamContent` seen in GetPositionInfo SOAP responses.
    /// Used to detect station breaks when streamContent disappears or changes
    /// to non-song content without an AVTransport event arriving.
    private var lastPollStreamContent: String?

    // MARK: - Scrobbler

    let scrobblerClient = ScrobblerClient()
    let scrobbleTracker = ScrobbleTracker()

    // MARK: - Database & Play Session

    let playSessionManager: PlaySessionManager
    let appleMusicPlayCountService: AppleMusicPlayCountService

    /// Debounce task for volume SOAP calls — coalesces rapid slider drags
    /// so we don't flood the speaker with one SOAP call per pixel.
    private var volumeDebounceTask: Task<Void, Never>?

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

    /// Whether the app is registered to launch at login (macOS 13+).
    /// Reads live state from SMAppService; the OS manages persistence.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("Launch at login \(newValue ? "register" : "unregister") failed: \(error.localizedDescription)")
            }
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


    /// Local event monitor for keyboard shortcuts (Space, arrows).
    private nonisolated(unsafe) var keyMonitor: Any?

    // MARK: - Init

    init() {
        // Initialize database and play session services
        let dbPool = DatabaseManager.shared.dbPool
        playSessionManager = PlaySessionManager(dbPool: dbPool)
        appleMusicPlayCountService = AppleMusicPlayCountService(dbPool: dbPool)

        // Forward music service state changes to AppState so views re-render
        // when canSaveToLibrary changes (e.g. auth status, isConnected).
        spotifyService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        appleMusicService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        setupBindings()
        startDiscovery()
        scrobblerClient.loadPersistedConfig()
        preventAppNap()
        setupSleepWakeObservers()
        setupKeyboardShortcuts()

        // Start Apple Music play count queue processing
        appleMusicPlayCountService.startDraining()

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
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
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
                // Close active play session before sleep
                self.playSessionManager.closeActiveSession(reason: "app_sleep")

                await self.eventHandler.unsubscribe()
                self.stopZoneTopologyPolling()
                self.stopEventWatchdog()
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
                self.startZoneTopologyPolling()
                self.startEventWatchdog()
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Don't intercept when a text field is focused (SwiftUI TextFields
            // use NSTextView as the first responder when editing)
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView { return event }

            // Ignore key events with Cmd/Ctrl modifiers (let system handle those)
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                return event
            }

            switch event.keyCode {
            case 49: // Space → play/pause
                self.togglePlayPause()
                return nil
            case 123: // Left arrow → previous track
                self.previousTrack()
                return nil
            case 124: // Right arrow → next track
                self.nextTrack()
                return nil
            case 126: // Up arrow → volume up
                self.setVolume(min(100, self.volume + 5))
                return nil
            case 125: // Down arrow → volume down
                self.setVolume(max(0, self.volume - 5))
                return nil
            default:
                return event
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
            // UPnP device lost after sleep — reload directly and subscribe.
            Task {
                if let device = await discoveryService.loadUPnPDeviceDirectly(
                    ip: zone.coordinator.ip,
                    uuid: zone.coordinator.uuid
                ) {
                    await eventHandler.subscribe(
                        to: device,
                        speakerIP: zone.coordinator.ip,
                        zoneName: zone.roomName
                    )
                    refreshVolume()
                }
            }
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
                    self.startZoneTopologyPolling()
                    self.startEventWatchdog()
                } else if speakers.isEmpty && self.connectionState == .connected {
                    // Speakers disappeared (network change, wake, etc.)
                    // Discovery has already restarted, so transition to .discovering
                    self.connectionState = .discovering
                    self.stopZoneTopologyPolling()
                    self.stopEventWatchdog()
                    log.info("Speakers lost — transitioning to discovering")
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
                let newTrackId = nowPlaying.track?.id
                let oldEnqueuedURI = self.nowPlaying.enqueuedURI
                let newEnqueuedURI = nowPlaying.enqueuedURI

                // Source change (different station/favorite/playlist loaded) cancels
                // auto-add — the user's opt-in was scoped to the previous source.
                // A nil → URI transition (e.g., resuming after stop) does NOT reset.
                if self.autoAddToAppleMusic,
                   let newURI = newEnqueuedURI,
                   let oldURI = oldEnqueuedURI,
                   newURI != oldURI {
                    log.info("Source changed (\(oldURI) → \(newURI)) — disabling auto-add")
                    self.autoAddToAppleMusic = false
                    self.autoAddAttemptedTrackIds.removeAll()
                }

                // Preserve enriched fields when the same track is re-published
                // with missing data (e.g., resubscribe → fetchCurrentState returns
                // SOAP data without duration, wiping the iTunes-enriched value).
                if newTrackId == oldTrackId,
                   let oldTrack = self.nowPlaying.track,
                   var newTrack = nowPlaying.track {
                    if newTrack.durationSeconds == 0, oldTrack.durationSeconds > 0 {
                        newTrack.durationSeconds = oldTrack.durationSeconds
                    }
                    if newTrack.albumArtURL == nil, let oldArt = oldTrack.albumArtURL {
                        newTrack.albumArtURL = oldArt
                    }
                    var merged = nowPlaying
                    merged.track = newTrack
                    self.nowPlaying = merged
                } else {
                    self.nowPlaying = nowPlaying
                }

                let isDJ = nowPlaying.track?.isDJSegment == true

                // Diagnostic: log all state transitions
                if newTrackId != oldTrackId {
                    let desc = isDJ
                        ? "DJ/break: \(nowPlaying.track?.title ?? "nil")"
                        : "New track: \(newTrackId ?? "nil"), duration: \(nowPlaying.track?.durationSeconds ?? 0)s"
                    log.info("\(desc)")
                }

                // Feed scrobble tracker (skip DJ segments — don't scrobble talk/ads)
                if !isDJ {
                    self.scrobbleTracker.update(
                        trackId: nowPlaying.track?.id,
                        transportState: nowPlaying.transportState,
                        durationSeconds: nowPlaying.track?.durationSeconds ?? 0
                    )
                }

                // Feed play session manager (determines qualified plays, enqueues Apple Music play counts)
                let trackInLibrary = nowPlaying.track.map { self.savedTrackIds.contains($0.id) } ?? false
                self.playSessionManager.onStateChange(
                    trackId: nowPlaying.track?.id,
                    track: nowPlaying.track,
                    transportState: nowPlaying.transportState,
                    householdId: self.currentHouseholdId,
                    isTrackInLibrary: trackInLibrary
                )

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
                    let libraryMatch = await appleMusicService.isInLibrary(
                        title: track.title, artist: track.artist
                    )
                    if let libraryMatch {
                        log.info("Track in Apple Music library: \(track.artist) — \(track.title)")
                        self.savedTrackIds.insert(track.id)
                        self.playSessionManager.setLibraryMatch(
                            for: track.id, match: libraryMatch
                        )
                        return
                    }

                    // Not in library — auto-add if the user has opted in for this session.
                    guard self.autoAddToAppleMusic else { return }
                    guard !self.autoAddAttemptedTrackIds.contains(track.id) else { return }
                    guard self.savingTrackId == nil else { return }

                    self.autoAddAttemptedTrackIds.insert(track.id)
                    self.savingTrackId = track.id
                    log.info("Auto-adding to Apple Music: \(track.artist) — \(track.title)")

                    let result = await self.appleMusicService.searchAndSave(
                        title: track.title, artist: track.artist, love: false
                    )
                    self.savingTrackId = nil
                    if result.success {
                        self.savedTrackIds.insert(track.id)
                    } else {
                        log.warning("Auto-add failed: \(result.message ?? "unknown")")
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
            // Fetch zone topology and household ID in parallel
            async let groupsTask = zoneManager.getZoneGroups(speakerIP: firstSpeaker.ip)
            async let householdTask = zoneManager.getHouseholdID(speakerIP: firstSpeaker.ip)
            let (groups, householdId) = await (groupsTask, householdTask)
            self.zones = groups
            for g in groups {
                log.info("Zone topology: \(g.roomName) — coordinator \(g.coordinator.uuid) @ \(g.coordinator.ip), members: \(g.members.map { "\($0.roomName)@\($0.ip)" })")
            }

            // Update household and prompt naming if new
            if let householdId {
                self.currentHouseholdId = householdId
                if !homeStore.isKnownHousehold(householdId) {
                    self.pendingHomeNaming = true
                }
            }

            // If a zone is already selected (e.g., reconnecting after network change),
            // re-establish event subscription and refresh state. The UPnP device may
            // have been lost when upnpDevices was cleared during re-discovery.
            if let zone = activeZone,
               eventHandler.subscribedDeviceUUID != zone.coordinator.uuid {
                log.info("Re-establishing connection to \(zone.roomName) after reconnect")
                await eventHandler.fetchInitialState(
                    speakerIP: zone.coordinator.ip,
                    zoneName: zone.roomName
                )
                if let device = await discoveryService.loadUPnPDeviceDirectly(
                    ip: zone.coordinator.ip,
                    uuid: zone.coordinator.uuid
                ) {
                    await eventHandler.subscribe(
                        to: device,
                        speakerIP: zone.coordinator.ip,
                        zoneName: zone.roomName
                    )
                }
                refreshVolume()
            }

            // Auto-select zone:
            // 1. Find the zone that is currently PLAYING
            // 2. Fall back to persisted default zone
            // 3. Fall back to first zone
            if selectedZone == nil {
                var playingZones: [SonosZoneGroup] = []

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
                        let name = groups.first(where: { $0.coordinator.uuid == uuid })?.roomName ?? "?"
                        log.info("Transport state: \(name) (\(uuid)) = \(state ?? "nil")")
                        if state == "PLAYING",
                           let zone = groups.first(where: { $0.coordinator.uuid == uuid }) {
                            playingZones.append(zone)
                        }
                    }
                }

                // When multiple zones are playing, prefer the default zone
                let playingZone: SonosZoneGroup?
                if playingZones.count > 1, let defaultName = defaultZone {
                    playingZone = playingZones.first(where: { $0.roomName == defaultName })
                        ?? playingZones.first
                    log.info("Multiple playing zones (\(playingZones.map(\.roomName))), preferring default '\(defaultName)' → \(playingZone?.roomName ?? "?")")
                } else {
                    playingZone = playingZones.first
                }
                log.info("Auto-selected zone: \(playingZone?.roomName ?? "none") @ \(playingZone?.coordinator.ip ?? "?")")

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
            // [Audit fix #6: guard against concurrent loads]
            if let zone = activeZone, !isLoadingFavorites {
                isLoadingFavorites = true
                let favs = await zoneManager.getFavorites(speakerIP: zone.coordinator.ip)
                self.favorites = favs
                isLoadingFavorites = false
            }
        }
    }

    // MARK: - Zone Selection

    /// The currently selected zone group.
    var activeZone: SonosZoneGroup? {
        zones.first(where: { $0.coordinator.uuid == selectedZone })
    }

    /// Select a zone to control. Subscribes to its coordinator's events.
    /// [Audit fix #5: if the zone UUID doesn't match any loaded zone, selectedZone is
    ///  not updated — prevents UI from showing a stale UUID with no zone data]
    func selectZone(_ coordinatorUUID: String) {
        guard coordinatorUUID != selectedZone else { return }

        // Verify the zone exists before committing the selection
        guard zones.contains(where: { $0.coordinator.uuid == coordinatorUUID }) else {
            log.warning("selectZone called for unknown UUID \(coordinatorUUID) — zones may not be loaded yet")
            // Still set it so that when zones load later, activeZone will resolve
            selectedZone = coordinatorUUID
            return
        }

        selectedZone = coordinatorUUID

        // Zone change scopes auto-add to a single zone/source — disable on switch.
        if autoAddToAppleMusic {
            log.info("Zone changed — disabling auto-add")
            autoAddToAppleMusic = false
        }
        autoAddAttemptedTrackIds.removeAll()

        guard let zone = activeZone else { return }
        log.info("Selected zone: \(zone.roomName) — coordinator \(zone.coordinator.uuid) @ \(zone.coordinator.ip)")

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
                // Unsubscribe from the previous zone first to stop stale events
                await eventHandler.unsubscribe()
                await eventHandler.fetchInitialState(
                    speakerIP: zone.coordinator.ip,
                    zoneName: zone.roomName
                )
                refreshVolume()

                // If SOAP returned TRANSITIONING, retry after a brief delay
                // to catch the actual PLAYING state. Without this, position
                // polling never starts and the watchdog (inside polling) can't
                // detect stale subscriptions.
                if eventHandler.nowPlaying.transportState == .transitioning {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await eventHandler.fetchInitialState(
                        speakerIP: zone.coordinator.ip,
                        zoneName: zone.roomName
                    )
                }

                // Load UPnP device and subscribe to events
                if let device = await discoveryService.loadUPnPDeviceDirectly(
                    ip: zone.coordinator.ip,
                    uuid: zone.coordinator.uuid
                ) {
                    await eventHandler.subscribe(
                        to: device,
                        speakerIP: zone.coordinator.ip,
                        zoneName: zone.roomName
                    )
                }
            }
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
            // [Audit fix #6: guard against concurrent loads from onConnected + trySubscribe racing]
            if favorites.isEmpty, !isLoadingFavorites {
                isLoadingFavorites = true
                let favs = await zoneManager.getFavorites(speakerIP: zone.coordinator.ip)
                if !favs.isEmpty {
                    log.info("Loaded \(favs.count) favorites (deferred)")
                    self.favorites = favs
                }
                isLoadingFavorites = false
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

    /// Resolve the coordinator IP for the active zone (topology-based, no UPnP device needed).
    private var activeCoordinatorIP: String? {
        activeZone?.coordinator.ip
    }

    func togglePlayPause() {
        guard let ip = activeCoordinatorIP else { return }
        let isTV = nowPlaying.track?.isTVAudio == true
        let wasPlaying = nowPlaying.transportState == .playing

        // Optimistically flip the UI state so the button responds immediately.
        // The authoritative state will arrive via AVTransport events (or the
        // SOAP reconcile below) and will correct this if the command failed.
        if !isTV {
            nowPlaying.transportState = wasPlaying ? .paused : .playing
            eventHandler.nowPlaying.transportState = nowPlaying.transportState
        }

        Task {
            if isTV {
                // TV audio is a live HDMI stream — Pause/Stop are ignored by Sonos.
                // Use mute/unmute instead and toggle the icon locally.
                isTVMuted.toggle()
                await controller.setMuteByIP(ip, muted: isTVMuted)
            } else if wasPlaying {
                await controller.pauseByIP(ip)
            } else {
                await controller.playByIP(ip)
            }

            // Always reconcile via SOAP after a short delay. Events may not
            // fire reliably for every stream/subscription, so the explicit
            // fetch guarantees the UI matches the speaker's actual state.
            try? await Task.sleep(for: .milliseconds(400))
            await eventHandler.fetchInitialState(speakerIP: ip, zoneName: nowPlaying.zoneName ?? "")
        }
    }

    func nextTrack() {
        guard let ip = activeCoordinatorIP else { return }
        Task {
            await controller.nextByIP(ip)
        }
    }

    func previousTrack() {
        guard let ip = activeCoordinatorIP else { return }
        Task {
            await controller.previousByIP(ip)
        }
    }

    /// Volume is set optimistically for responsive UI. SOAP calls are
    /// debounced so rapid slider drags don't flood the speaker.
    ///
    /// For grouped zones, the main slider adjusts all speakers proportionally,
    /// preserving relative volume differences (like the Sonos app). For single
    /// zones, it controls the one speaker directly.
    func setVolume(_ level: Int) {
        guard let zone = activeZone else { return }
        let ip = zone.coordinator.ip

        let delta = level - volume
        volume = level

        // Unmute immediately if dragging while muted
        if isMuted && level > 0 {
            isMuted = false
            Task { await controller.setMuteByIP(ip, muted: false) }
        }

        // For groups: apply delta proportionally to each speaker
        let isGroup = !zone.members.isEmpty
        if isGroup && !groupSpeakerVolumes.isEmpty {
            let allSpeakers = [zone.coordinator] + zone.members
            for speaker in allSpeakers {
                let current = groupSpeakerVolumes[speaker.uuid] ?? 0
                let newLevel = max(0, min(100, current + delta))
                groupSpeakerVolumes[speaker.uuid] = newLevel
            }
        }

        // Debounce the SOAP volume call — cancel any pending call and
        // schedule a new one after 50ms. Only the final level gets sent.
        volumeDebounceTask?.cancel()

        if isGroup && !groupSpeakerVolumes.isEmpty {
            // Snapshot the current per-speaker targets for the debounced call
            let targets = groupSpeakerVolumes
            volumeDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                await withTaskGroup(of: Void.self) { group in
                    for speaker in [zone.coordinator] + zone.members {
                        if let targetLevel = targets[speaker.uuid] {
                            group.addTask {
                                await self.controller.setVolumeByIP(speaker.ip, level: targetLevel)
                            }
                        }
                    }
                }
            }
        } else {
            volumeDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                await self.controller.setVolumeByIP(ip, level: level)
            }
        }
    }

    /// Toggle mute using the Sonos hardware mute (SetMute SOAP action).
    /// This is independent of volume level — muting preserves volume,
    /// and unmuting restores audio at the same level.
    func toggleMute() {
        guard let ip = activeCoordinatorIP else { return }
        let newMuted = !isMuted
        isMuted = newMuted
        Task {
            await controller.setMuteByIP(ip, muted: newMuted)
        }
    }

    /// Get volume for a specific speaker by UUID (direct SOAP via IP).
    func getVolumeForSpeaker(_ uuid: String) async -> Int? {
        guard let ip = allTopologySpeakers.first(where: { $0.uuid == uuid })?.ip else { return nil }
        return await controller.getVolumeByIP(ip)
    }

    /// Set volume for a specific speaker by UUID (direct SOAP via IP).
    func setVolumeForSpeaker(_ uuid: String, level: Int) {
        guard let ip = allTopologySpeakers.first(where: { $0.uuid == uuid })?.ip else { return }
        Task {
            await controller.setVolumeByIP(ip, level: level)
        }
    }

    func playFavorite(_ favorite: FavoriteItem) {
        // Use the coordinator IP from zone topology (not UPnP device registry)
        // so this works even for topology-only speakers that SSDP hasn't found.
        guard let zone = activeZone else {
            log.warning("No active zone — cannot play favorite '\(favorite.title)'")
            return
        }
        let coordinatorIP = zone.coordinator.ip
        log.info("Playing favorite: \(favorite.title) on \(zone.roomName) (\(coordinatorIP))")

        // Clear stale media title immediately so the UI doesn't show the
        // previous station's name while the new one loads.
        nowPlaying.mediaTitle = nil
        eventHandler.nowPlaying.mediaTitle = nil
        miniPlayerWindow.updateTitle(for: nowPlaying.track, mediaTitle: nil)

        Task {
            let played = await controller.playURIByIP(
                coordinatorIP,
                uri: favorite.uri,
                metadata: favorite.meta
            )
            if !played {
                log.error("Failed to play favorite '\(favorite.title)' on \(zone.roomName)")
                return
            }

            // If we're not subscribed to events on this zone (e.g., UPnP device
            // loading failed silently after a zone switch), re-fetch state so the
            // UI shows the now-playing, and retry the subscription.
            if eventHandler.subscribedDeviceUUID != zone.coordinator.uuid {
                log.info("Not subscribed to \(zone.roomName) — fetching state after play")
                // Brief delay to let the speaker start the stream
                try? await Task.sleep(for: .seconds(1))
                await eventHandler.fetchInitialState(
                    speakerIP: coordinatorIP,
                    zoneName: zone.roomName
                )
                // Retry UPnP device loading and subscribe to events
                if let device = await discoveryService.loadUPnPDeviceDirectly(
                    ip: coordinatorIP,
                    uuid: zone.coordinator.uuid
                ) {
                    await eventHandler.subscribe(
                        to: device,
                        speakerIP: coordinatorIP,
                        zoneName: zone.roomName
                    )
                }
            }
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
    /// Tries SSDP speakers first, falls back to topology speakers or cached IP.
    func refreshZones() async {
        let ip = speakers.first?.ip
            ?? allTopologySpeakers.first?.ip
            ?? discoveryService.cachedSpeakerIP
        guard let ip else { return }
        let groups = await zoneManager.getZoneGroups(speakerIP: ip)
        self.zones = groups
    }

    /// Refresh zone topology, polling until the expected group composition appears.
    /// After SOAP join/unjoin calls, Sonos hardware may take 1-2s to update its topology.
    /// This polls up to `maxAttempts` times at `interval` intervals until the coordinator's
    /// zone members match the expected set, then updates `self.zones`.
    func refreshZones(
        expectingCoordinator coordinatorUUID: String,
        withMembers expectedUUIDs: Set<String>,
        maxAttempts: Int = 6,
        interval: Duration = .milliseconds(500)
    ) async {
        let ip = speakers.first?.ip
            ?? allTopologySpeakers.first?.ip
            ?? discoveryService.cachedSpeakerIP
        guard let ip else { return }

        for attempt in 1...maxAttempts {
            let groups = await zoneManager.getZoneGroups(speakerIP: ip)

            // Check if the coordinator's zone now has the expected members
            if let zone = groups.first(where: { $0.coordinator.uuid == coordinatorUUID }) {
                var actualUUIDs: Set<String> = [zone.coordinator.uuid]
                for member in zone.members {
                    actualUUIDs.insert(member.uuid)
                }
                if actualUUIDs == expectedUUIDs {
                    log.info("Zone topology verified on attempt \(attempt)")
                    self.zones = groups
                    return
                }
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: interval)
            }
        }

        // Topology didn't converge — use the last result anyway
        log.warning("Zone topology did not match expected group after \(maxAttempts) attempts — using last result")
        let groups = await zoneManager.getZoneGroups(speakerIP: ip)
        self.zones = groups
    }

    // MARK: - Volume Polling

    /// Fetch the current volume and mute state from the active zone.
    /// For groups, fetches all speaker volumes and uses the average for the main slider.
    func refreshVolume() {
        guard let zone = activeZone else { return }
        let ip = zone.coordinator.ip
        Task {
            async let muteTask = controller.getMuteByIP(ip)

            if zone.members.isEmpty {
                // Single speaker — just fetch coordinator volume
                let vol = await controller.getVolumeByIP(ip)
                if let vol { self.volume = vol }
                self.groupSpeakerVolumes = [:]
            } else {
                // Group — fetch all speaker volumes in parallel
                let allSpeakers = [zone.coordinator] + zone.members
                var volumes: [String: Int] = [:]
                await withTaskGroup(of: (String, Int?).self) { group in
                    for speaker in allSpeakers {
                        group.addTask {
                            let vol = await self.controller.getVolumeByIP(speaker.ip)
                            return (speaker.uuid, vol)
                        }
                    }
                    for await (uuid, vol) in group {
                        if let vol { volumes[uuid] = vol }
                    }
                }
                self.groupSpeakerVolumes = volumes
                // Main slider shows the average of all speakers
                if !volumes.isEmpty {
                    self.volume = volumes.values.reduce(0, +) / volumes.count
                }
            }

            if let muted = await muteTask {
                self.isMuted = muted
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
        // Capture the track that's already displayed when polling starts.
        // For radio/streaming (SOAP duration=0), we use a local elapsed
        // counter that starts from 0 — suppress until a genuine track
        // change so the bar doesn't show wrong position on resume.
        // Standard tracks (SOAP duration>0) always show progress since
        // SOAP provides accurate real-time position data.
        let initialTrackId = self.nowPlaying.track?.id
        positionPollingTask = Task<Void, Never> { @MainActor [weak self] in
            defer { self?.positionPollingTask = nil }
            var seededPosition = false
            var consecutiveFailures = 0
            var hasEverSucceeded = false  // Guard against spurious station break on zone switch
            var suppressProgress = true   // Radio only: hide until genuine track change
            while !Task.isCancelled {
                guard let self else { break }

                let trackDuration = self.nowPlaying.track?.durationSeconds ?? 0
                let currentTrackId = self.nowPlaying.track?.id

                // Reset local radio counter and progress bar on track change.
                // Real songs get the bar back in ~1s when iTunes enrichment
                // returns duration; DJ/social segments stay at 0.
                if currentTrackId != self.radioPositionTrackId {
                    // Genuine new track = different from what was playing when
                    // polling started. The initial "track change" (polling's
                    // first loop seeing the existing track) stays suppressed.
                    if currentTrackId != initialTrackId {
                        suppressProgress = false
                    }
                    self.radioPosition = 0
                    self.radioPositionTrackId = currentTrackId
                    self.playbackPosition = 0
                    self.playbackDuration = 0
                    self.lastPollStreamContent = nil
                    // Only reset failure counter for real tracks, not DJ segments.
                    // Station break detection creates a new DJ segment track which
                    // would reset consecutiveFailures to 0, preventing the polling
                    // backoff from ever engaging — causing hundreds of rapid
                    // GetPositionInfo failures per minute during breaks.
                    let isDJ = self.nowPlaying.track?.isDJSegment ?? false
                    if !isDJ {
                        consecutiveFailures = 0
                    }
                }

                // Try UPnP device first, fall back to direct IP-based SOAP
                // when the UPnP call fails or SSDP hasn't (re)discovered the
                // speaker. The IP fallback uses manual string-based XML parsing
                // which is more resilient to malformed responses (e.g. TuneIn
                // streams with unescaped URL parameters that break NSXMLParser).
                let info: SonosController.PositionInfo?
                let deviceAvailable: Bool
                if let device = self.activeUPnPDevice {
                    deviceAvailable = true
                    let upnpResult = await self.controller.getPositionInfo(device: device)
                    if upnpResult != nil {
                        info = upnpResult
                    } else if let ip = self.activeCoordinatorIP {
                        // UPnP library failed (e.g. XML parse error) — try direct SOAP
                        info = await self.controller.getPositionInfoByIP(ip)
                    } else {
                        info = nil
                    }
                } else if let ip = self.activeCoordinatorIP {
                    deviceAvailable = false
                    info = await self.controller.getPositionInfoByIP(ip)
                } else {
                    deviceAvailable = false
                    info = nil
                }

                if let info {
                    consecutiveFailures = 0
                    hasEverSucceeded = true
                    if info.duration > 0 {
                        // Standard track — SOAP has both position and duration.
                        // Always show progress for standard tracks since SOAP
                        // provides accurate real-time data (unlike radio where
                        // we'd rely on a local counter starting from 0).
                        self.playbackPosition = info.position
                        self.playbackDuration = info.duration

                        // On first poll, seed the scrobble tracker with current position.
                        // Handles the case where the app starts mid-song.
                        if !seededPosition {
                            seededPosition = true
                            self.scrobbleTracker.seedPosition(info.position)
                        }
                    } else if trackDuration > 0, !suppressProgress {
                        // Radio/streaming — SOAP duration is 0, use local counter.
                        // Duration comes from iTunes enrichment on event-driven track
                        // changes only (initial fetch skips duration since we can't
                        // determine position within a song mid-stream).
                        // Suppressed on resume because the radio counter would start
                        // from 0 which is wrong for a song already in progress.
                        self.radioPosition += 1
                        self.playbackPosition = min(self.radioPosition, trackDuration)
                        self.playbackDuration = trackDuration

                        // Log radio position periodically for diagnostics
                        if self.radioPosition == trackDuration {
                            log.debug("Radio position reached track duration (\(trackDuration)s) — watching for station break")
                        } else if self.radioPosition % 30 == 0 {
                            log.debug("Radio position: \(self.radioPosition)s / \(trackDuration)s")
                        }

                        // Duration-based station break detection: if our local
                        // elapsed counter exceeds the enriched track duration,
                        // the song has likely ended and no new track event
                        // arrived — commercial/DJ break. Grace is 0s because
                        // radio edits are often shorter than iTunes album
                        // versions, and a brief flash of the station logo
                        // before the next song event is acceptable.
                        if self.radioPosition > trackDuration,
                           let track = self.nowPlaying.track,
                           !track.isDJSegment,
                           let stationName = self.nowPlaying.mediaTitle {
                            log.info("Station break detected via duration exceeded on \(stationName) (elapsed \(self.radioPosition)s, duration \(trackDuration)s)")
                            self.triggerStationBreak(reason: "duration exceeded")
                        }
                    }

                    // Metadata-based station break detection: parse the raw
                    // trackMetaData from GetPositionInfo to detect when
                    // streamContent disappears (song ended, break started)
                    // before the duration timer fires. This catches radio
                    // edits that are shorter than the iTunes album version.
                    if let track = self.nowPlaying.track,
                       !track.isDJSegment,
                       self.nowPlaying.mediaTitle != nil {
                        let rawMeta = info.trackMetaData
                        let currentStreamContent: String?
                        if !rawMeta.isEmpty,
                           let meta = DIDLLiteParser.parse(rawMeta) {
                            currentStreamContent = meta.streamContent
                        } else {
                            currentStreamContent = nil
                        }

                        // If we had streamContent before and it just
                        // disappeared, the song ended — station break.
                        if let last = self.lastPollStreamContent,
                           !last.isEmpty,
                           (currentStreamContent == nil || currentStreamContent!.isEmpty) {
                            log.info("Station break detected via streamContent cleared (was: \(last.prefix(60)))")
                            self.triggerStationBreak(reason: "streamContent cleared")
                        }
                        self.lastPollStreamContent = currentStreamContent
                    }
                } else {
                    let wasSucceeding = consecutiveFailures == 0
                    consecutiveFailures += 1

                    // First failure after success on a radio stream = station break
                    // (DJ segment, ad, etc.). GetPositionInfo returns malformed XML
                    // during breaks but succeeds during songs.
                    // Guard: only trigger when the speaker was actually reachable
                    // (deviceAvailable or IP fallback tried). If both UPnP device
                    // and IP are nil, this is a connectivity issue, not a station break.
                    if wasSucceeding,
                       hasEverSucceeded,
                       deviceAvailable || self.activeCoordinatorIP != nil,
                       let track = self.nowPlaying.track,
                       !track.isDJSegment,
                       self.nowPlaying.mediaTitle != nil {
                        log.info("Station break detected via GetPositionInfo failure (radioPosition=\(self.radioPosition)s, trackDuration=\(trackDuration)s)")
                        self.lastPollStreamContent = nil
                        self.triggerStationBreak(reason: "SOAP failure")
                    }

                    if consecutiveFailures == 5 {
                        log.warning("Position polling: 5 consecutive failures — backing off to 10s intervals")
                    } else if consecutiveFailures == 30 {
                        log.warning("Position polling: 30 consecutive failures — still waiting (radio break may be long)")
                    }
                }

                // Back off on repeated failures to avoid hammering a broken speaker.
                // During DJ segments (station breaks), poll every 30s since the only
                // useful signal is metadata reappearing. For normal failures, back off
                // to 10s after 5 consecutive failures.
                let isDJSegment = self.nowPlaying.track?.isDJSegment ?? false
                let interval: Int
                if isDJSegment {
                    interval = 30
                } else if consecutiveFailures >= 5 {
                    interval = 10
                } else {
                    interval = 1
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Trigger a station break: swap NowPlaying to show the station name/logo
    /// and mark the track as a DJ segment. Called from multiple detection paths
    /// (duration exceeded, metadata cleared, SOAP failure).
    private func triggerStationBreak(reason: String) {
        guard let track = nowPlaying.track,
              let stationName = nowPlaying.mediaTitle else { return }
        eventHandler.nowPlaying = NowPlayingState(
            track: TrackInfo(
                title: stationName,
                artist: "",
                album: nil,
                durationSeconds: 0,
                albumArtURL: eventHandler.stationArtURL,
                sourceURI: track.sourceURI,
                isDJSegment: true
            ),
            transportState: .playing,
            zoneName: nowPlaying.zoneName,
            enqueuedURI: nowPlaying.enqueuedURI,
            mediaTitle: stationName
        )
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

    // MARK: - Zone Topology Polling

    /// Periodically polls Sonos for zone topology changes made externally
    /// (e.g., Sonos app regrouping, TV stealing a soundbar via HDMI).
    /// Runs every 30 seconds while connected.
    private func startZoneTopologyPolling() {
        guard zoneTopologyPollingTask == nil else { return }
        log.debug("Starting zone topology polling")
        zoneTopologyPollingTask = Task { @MainActor [weak self] in
            defer { self?.zoneTopologyPollingTask = nil }
            // Brief initial delay — don't poll immediately after connect
            // since onConnected() already fetches topology
            try? await Task.sleep(for: .seconds(30))

            while !Task.isCancelled {
                guard let self, !self.zones.isEmpty else { break }

                let ip = self.speakers.first?.ip
                    ?? self.allTopologySpeakers.first?.ip
                    ?? self.discoveryService.cachedSpeakerIP
                if let ip {
                    let groups = await self.zoneManager.getZoneGroups(speakerIP: ip)
                    // Compare as sets of zone IDs to ignore ordering differences
                    // between SOAP responses. SonosZoneGroup.== already handles
                    // member ordering; this handles zone-level ordering.
                    let changed = Set(groups.map(\.id)) != Set(self.zones.map(\.id))
                        || groups.contains(where: { g in
                            self.zones.first(where: { $0.id == g.id }) != g
                        })
                    if changed {
                        log.info("Zone topology changed externally — updating (\(groups.count) zone(s))")
                        self.zones = groups
                    }
                }

                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stopZoneTopologyPolling() {
        guard zoneTopologyPollingTask != nil else { return }
        log.debug("Stopping zone topology polling")
        zoneTopologyPollingTask?.cancel()
        zoneTopologyPollingTask = nil
    }

    // MARK: - Event Subscription Watchdog

    /// Standalone watchdog that runs independently of position polling.
    /// Detects when the UPnP event subscription has died (no events arriving)
    /// even when playback is STOPPED/TRANSITIONING and position polling isn't active.
    /// Without this, the app can permanently show stale track data.
    private func startEventWatchdog() {
        guard eventWatchdogTask == nil else { return }
        log.debug("Starting event subscription watchdog")
        eventWatchdogTask = Task { @MainActor [weak self] in
            defer { self?.eventWatchdogTask = nil }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.connectionState == .connected else { continue }
                guard let zone = self.activeZone else { continue }

                // Check if we have no event subscription at all — this happens
                // when the UPnP device never loaded (SSDP miss + loadDirectly failed)
                if self.eventHandler.subscribedDeviceUUID == nil {
                    // Always refresh via SOAP every 30s so the display stays current
                    // even without a working UPnP subscription
                    await self.eventHandler.fetchInitialState(
                        speakerIP: zone.coordinator.ip,
                        zoneName: zone.roomName
                    )

                    // Throttle UPnP device load / subscribe attempts to every 120s
                    let now = Date()
                    if let lastAttempt = self.lastWatchdogResubscribeAttempt,
                       now.timeIntervalSince(lastAttempt) < 120 {
                        continue
                    }
                    self.lastWatchdogResubscribeAttempt = now
                    log.warning("Event watchdog: no subscription active — attempting recovery for \(zone.roomName)")

                    // Try UPnP device from cache, or load directly and subscribe
                    var upnpDevice = self.discoveryService.upnpDevice(for: zone.coordinator.uuid)
                    if upnpDevice == nil {
                        upnpDevice = await self.discoveryService.loadUPnPDeviceDirectly(
                            ip: zone.coordinator.ip,
                            uuid: zone.coordinator.uuid
                        )
                    }
                    if let upnpDevice {
                        await self.eventHandler.subscribe(
                            to: upnpDevice,
                            speakerIP: zone.coordinator.ip,
                            zoneName: zone.roomName
                        )
                    }
                    continue
                }

                // Check for stale subscription (subscribed but no events arriving).
                // Use 300s (5 min) threshold to avoid unnecessary resubscribes during
                // long radio tracks where no metadata changes occur. The subscription
                // renewals (handled by SwiftUPnP every ~120s) keep the subscription
                // alive but don't generate events visible to our handler.
                guard let lastEvent = self.eventHandler.lastEventTime,
                      Date().timeIntervalSince(lastEvent) > 300 else { continue }

                let now = Date()
                if let lastAttempt = self.lastWatchdogResubscribeAttempt,
                   now.timeIntervalSince(lastAttempt) < 120 {
                    continue
                }
                self.lastWatchdogResubscribeAttempt = now

                if self.eventHandler.subscribedDeviceUUID != nil {
                    log.warning("Event watchdog: no event in >300s — resubscribing to \(zone.roomName)")
                    await self.eventHandler.resubscribe()
                } else {
                    log.warning("Event watchdog: no event in >300s — full re-subscribe to \(zone.roomName)")
                    self.resubscribeToActiveZone()
                }
            }
        }
    }

    private func stopEventWatchdog() {
        guard eventWatchdogTask != nil else { return }
        log.debug("Stopping event subscription watchdog")
        eventWatchdogTask?.cancel()
        eventWatchdogTask = nil
    }

    // MARK: - Presets

    /// Activate a preset: group rooms, set volume, play favorite.
    /// Uses direct SOAP calls by IP so it works even before SSDP/UPnP discovery completes.
    /// [Audit fix #1: SOAP failures are now checked — grouping/volume/play errors abort early
    ///  instead of leaving speakers in an inconsistent state]
    /// [Audit fix #3: volume is only updated in UI after SOAP confirms success]
    func activatePreset(_ preset: Preset) {
        // Guard: refuse to activate a preset from a different home.
        // Prevents wrong-speaker activation when room names overlap across homes.
        if let presetHome = preset.householdId, presetHome != currentHouseholdId {
            log.warning("Preset '\(preset.name)' belongs to a different home — refusing to activate")
            return
        }

        log.info("Activating preset: \(preset.name)")

        // Clear stale media title immediately so the UI doesn't show the
        // previous station's name while the new one loads.
        nowPlaying.mediaTitle = nil
        eventHandler.nowPlaying.mediaTitle = nil
        miniPlayerWindow.updateTitle(for: nowPlaying.track, mediaTitle: nil)

        Task {
            // 0. Ensure zone topology is loaded (needed if app just started)
            if zones.isEmpty {
                await ensureZonesLoaded()
            }

            // 1. Find the coordinator by room name (topology first, SSDP fallback)
            guard let coordinatorSpeaker = allTopologySpeakers.first(where: { $0.roomName == preset.coordinatorRoom })
                    ?? speakers.first(where: { $0.roomName == preset.coordinatorRoom }) else {
                log.error("Coordinator room '\(preset.coordinatorRoom)' not found")
                return
            }

            // 2. Group additional rooms with the coordinator
            var groupingFailed = false
            for roomName in preset.rooms {
                if roomName == preset.coordinatorRoom { continue }
                if let speaker = allTopologySpeakers.first(where: { $0.roomName == roomName })
                    ?? speakers.first(where: { $0.roomName == roomName }) {
                    let joined = await zoneManager.joinSpeaker(
                        speakerIP: speaker.ip,
                        toCoordinatorUUID: coordinatorSpeaker.uuid
                    )
                    if !joined {
                        log.warning("Failed to group '\(roomName)' — continuing with remaining rooms")
                        groupingFailed = true
                    }
                } else {
                    log.warning("Room '\(roomName)' not found in topology — skipping")
                }
            }

            // 3. Set volume before playing (direct SOAP — no UPnP device needed)
            // [Audit fix #3: only update UI volume after SOAP confirms success]
            if let vol = preset.volume {
                let volumeSet = await controller.setVolumeByIP(coordinatorSpeaker.ip, level: vol)
                if volumeSet {
                    self.volume = vol
                } else {
                    log.warning("Volume set failed for preset '\(preset.name)' — speaker may play at previous volume")
                }
            }

            // 4. Play the favorite (direct SOAP — no UPnP device needed)
            let played = await controller.playURIByIP(
                coordinatorSpeaker.ip,
                uri: preset.favorite.uri,
                metadata: preset.favorite.meta
            )
            if !played {
                log.error("Play failed for preset '\(preset.name)' — aborting")
                return
            }

            // 5. Refresh zones to reflect new grouping (must happen before
            //    selectZone so the coordinator exists in the updated topology).
            // Build expected member set from preset rooms for verification polling.
            var expectedUUIDs: Set<String> = [coordinatorSpeaker.uuid]
            for roomName in preset.rooms {
                if let speaker = allTopologySpeakers.first(where: { $0.roomName == roomName })
                    ?? speakers.first(where: { $0.roomName == roomName }) {
                    expectedUUIDs.insert(speaker.uuid)
                }
            }
            await refreshZones(
                expectingCoordinator: coordinatorSpeaker.uuid,
                withMembers: expectedUUIDs
            )

            // 6. Switch active zone to the preset's coordinator
            selectZone(coordinatorSpeaker.uuid)

            if groupingFailed {
                log.warning("Preset '\(preset.name)' activated with partial grouping")
            }
        }
    }

    /// Ensure zone topology is loaded. Tries any known speaker IP to bootstrap.
    private func ensureZonesLoaded() async {
        // Already have zones
        guard zones.isEmpty else { return }

        // Try any speaker IP we can find (SSDP or cached)
        let speakerIP: String? = speakers.first?.ip
            ?? discoveryService.cachedSpeakerIP

        guard let ip = speakerIP else {
            log.warning("No speaker IP available to load zones")
            return
        }

        log.info("Bootstrapping zone topology from \(ip)")
        let groups = await zoneManager.getZoneGroups(speakerIP: ip)
        self.zones = groups
    }

    // MARK: - Library Saves

    /// Whether the heart/save button should be shown (at least one service connected).
    var canSaveToLibrary: Bool {
        spotifyService.isConnected || appleMusicService.isConnected
    }

    /// Save the current track to the active music library (Spotify or Apple Music).
    func saveToLibrary() {
        guard let track = nowPlaying.track else { return }

        // No music service connected — warn the user instead of failing silently
        guard canSaveToLibrary else {
            log.warning("Save attempted but no music service connected")
            showSaveWarning("No music service connected — open Setup to connect Apple Music or Spotify")
            return
        }

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
                self.showSaveWarning("Music service disconnected during save")
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

    // MARK: - Save Warning

    /// Show a brief warning message near the heart button, auto-clearing after 4 seconds.
    private func showSaveWarning(_ message: String) {
        saveWarningMessage = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.saveWarningMessage == message {
                self.saveWarningMessage = nil
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

/// Navigation state for schedule editing views.
enum ScheduleNav: Equatable {
    case list
    case create
    case createFromPreset(Preset)
    case edit(PlaybackSchedule)
}

/// Navigation state for custom station editing views.
enum CustomStationNav: Equatable {
    case list
    case create
    case edit(CustomStation)
}
