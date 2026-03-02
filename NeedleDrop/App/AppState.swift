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

    // MARK: - Playback Controls (stubs — Phase 3)

    func togglePlayPause() {
        log.info("togglePlayPause — not yet implemented")
    }

    func nextTrack() {
        log.info("nextTrack — not yet implemented")
    }

    func previousTrack() {
        log.info("previousTrack — not yet implemented")
    }

    func setVolume(_ level: Int) {
        log.info("setVolume(\(level)) — not yet implemented")
    }

    func playFavorite(_ favorite: FavoriteItem) {
        log.info("playFavorite(\(favorite.title)) — not yet implemented")
    }
}
