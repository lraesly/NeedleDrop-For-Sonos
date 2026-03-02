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
        eventHandler.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nowPlaying in
                self?.nowPlaying = nowPlaying
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
}
