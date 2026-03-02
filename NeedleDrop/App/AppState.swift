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

    // MARK: - Scrobbler

    let scrobblerClient = ScrobblerClient()
    let scrobbleTracker = ScrobbleTracker()

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

    // MARK: - Init

    init() {
        setupBindings()
        startDiscovery()
        scrobblerClient.loadPersistedConfig()
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
            }
            .store(in: &cancellables)

        // Mirror event handler's now-playing state to app state
        // and feed scrobble tracker
        eventHandler.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nowPlaying in
                guard let self else { return }
                self.nowPlaying = nowPlaying
                self.scrobbleTracker.update(
                    trackId: nowPlaying.track?.id,
                    transportState: nowPlaying.transportState,
                    durationSeconds: nowPlaying.track?.durationSeconds ?? 0
                )
            }
            .store(in: &cancellables)
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

            // Auto-select first zone if none selected
            if selectedZone == nil, let first = groups.first {
                selectZone(first.coordinator.uuid)
            }

            // Fetch favorites from the coordinator
            if let device = activeUPnPDevice {
                let favs = await zoneManager.getFavorites(device: device)
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

    func togglePlayPause() {
        guard let device = activeUPnPDevice else { return }
        Task {
            if nowPlaying.transportState == .playing {
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

    func playFavorite(_ favorite: FavoriteItem) {
        guard let device = activeUPnPDevice else { return }
        log.info("Playing favorite: \(favorite.title)")
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
        guard let zone = activeZone,
              let speakerDevice = discoveryService.upnpDevice(for: speakerUUID) else { return }
        Task {
            await zoneManager.joinSpeaker(speaker: speakerDevice, toCoordinator: zone.coordinator)
            // Refresh zones after grouping change
            await refreshZones()
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

    // MARK: - Presets

    /// Activate a preset: group rooms, set volume, play favorite.
    func activatePreset(_ preset: Preset) {
        log.info("Activating preset: \(preset.name)")
        Task {
            // 1. Find the coordinator by room name
            guard let coordinatorSpeaker = speakers.first(where: { $0.roomName == preset.coordinatorRoom }) else {
                log.error("Coordinator room '\(preset.coordinatorRoom)' not found")
                return
            }

            // 2. Group/ungroup rooms as needed
            for roomName in preset.rooms {
                if roomName == preset.coordinatorRoom { continue }
                if let speaker = speakers.first(where: { $0.roomName == roomName }),
                   let upnpDevice = discoveryService.upnpDevice(for: speaker.uuid) {
                    await zoneManager.joinSpeaker(speaker: upnpDevice, toCoordinator: coordinatorSpeaker)
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

    /// Save the current track to connected music libraries (Spotify + Apple Music).
    func saveToLibrary() {
        guard let track = nowPlaying.track else { return }
        log.info("Saving to library: \(track.artist) – \(track.title)")

        Task {
            var results: [ServiceSaveResult] = []

            // Run both saves concurrently
            async let spotifyResult: ServiceSaveResult? = spotifyService.isConnected
                ? spotifyService.searchAndSave(title: track.title, artist: track.artist)
                : nil

            async let appleMusicResult: ServiceSaveResult? = appleMusicService.isConnected
                ? appleMusicService.searchAndSave(title: track.title, artist: track.artist)
                : nil

            if let result = await spotifyResult { results.append(result) }
            if let result = await appleMusicResult { results.append(result) }

            self.lastSaveResult = LibrarySaveDetail(
                trackId: track.id,
                results: results
            )

            // Clear result after a few seconds
            Task {
                try? await Task.sleep(for: .seconds(5))
                if self.lastSaveResult?.trackId == track.id {
                    self.lastSaveResult = nil
                }
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
