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

                    // Auto-subscribe to first speaker's events if not already subscribed
                    self.autoSubscribeToEvents()
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

    // MARK: - Event Subscription

    /// Auto-subscribe to the first available speaker's AVTransport events.
    /// In Phase 4 this will become zone-aware (subscribe to coordinator only).
    private func autoSubscribeToEvents() {
        // Find a speaker that has a UPnP device with loaded services
        guard let speaker = speakers.first,
              let upnpDevice = discoveryService.upnpDevice(for: speaker.uuid) else {
            log.debug("No UPnP device available yet for event subscription")
            return
        }

        Task {
            await eventHandler.subscribe(
                to: upnpDevice,
                speakerIP: speaker.ip,
                zoneName: speaker.roomName
            )
        }
    }

    // MARK: - Active Device

    /// The UPnP device we're currently subscribed to (the coordinator).
    /// All control commands target this device.
    private var activeUPnPDevice: UPnPDevice? {
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
