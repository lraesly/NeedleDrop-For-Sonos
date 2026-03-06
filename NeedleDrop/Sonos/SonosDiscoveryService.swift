import AppKit
import Foundation
import Combine
import Network
import os
import SwiftUPnP

private let log = Logger(subsystem: "com.needledrop", category: "SonosDiscovery")

/// Discovers Sonos speakers on the local network using SSDP and cached IPs.
///
/// On launch, loads cached speaker IPs from UserDefaults and tries a direct HTTP
/// fetch of each speaker's device description XML (fast path, <1s). SSDP discovery
/// runs in the background to find new speakers.
@MainActor
final class SonosDiscoveryService: ObservableObject {
    @Published var speakers: [SonosDevice] = []
    @Published var isDiscovering = false

    /// UPnP device objects from SSDP discovery, keyed by UUID.
    /// These have loaded services (AVTransport, RenderingControl, etc.)
    /// needed for event subscriptions and SOAP control.
    private var upnpDevices: [String: UPnPDevice] = [:]

    private let speakerStore: SpeakerStore
    private var cancellables = Set<AnyCancellable>()
    private var pathMonitor: NWPathMonitor?
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []

    /// The UPnP device type for Sonos ZonePlayers.
    private static let sonosDeviceType = "urn:schemas-upnp-org:device:ZonePlayer:1"

    init(speakerStore: SpeakerStore) {
        self.speakerStore = speakerStore
        setupNetworkMonitor()
        setupWakeObserver()
    }

    deinit {
        pathMonitor?.cancel()
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Discovery

    /// Start discovering Sonos speakers. Tries cached IPs first (fast path),
    /// then starts background SSDP discovery.
    func startDiscovery() {
        isDiscovering = true

        // Fast path: probe cached speaker IPs
        let cached = speakerStore.loadCachedSpeakers()
        if !cached.isEmpty {
            log.info("Probing \(cached.count) cached speaker IPs")
            Task {
                await probeCachedSpeakers(cached)
            }
        }

        // Background: SSDP multicast discovery
        startSSDPDiscovery()
    }

    func stopDiscovery() {
        UPnPRegistry.shared.stopDiscovery()
        isDiscovering = false
    }

    /// Get the UPnP device for a speaker UUID (needed for event subscriptions).
    /// Returns nil if the speaker was only found via cached IP probe (no SSDP yet).
    func upnpDevice(for uuid: String) -> UPnPDevice? {
        upnpDevices[uuid]
    }

    /// A cached speaker IP from UserDefaults, for bootstrapping zone topology
    /// before SSDP discovery completes.
    var cachedSpeakerIP: String? {
        speakerStore.loadCachedSpeakers().first?.ip
    }

    // MARK: - Cached IP Fast Path

    /// Probe known speaker IPs by fetching their device description XML directly.
    /// This avoids the potentially slow SSDP multicast and gives results in <1s.
    private func probeCachedSpeakers(_ cached: [CachedSpeaker]) async {
        await withTaskGroup(of: SonosDevice?.self) { group in
            for speaker in cached {
                group.addTask {
                    await self.probeIP(speaker.ip, knownUUID: speaker.uuid, knownName: speaker.roomName)
                }
            }

            for await device in group {
                if let device {
                    addOrUpdateSpeaker(device)
                }
            }
        }
    }

    /// Try to reach a Sonos speaker at a known IP by fetching its device description.
    private nonisolated func probeIP(_ ip: String, knownUUID: String?, knownName: String?) async -> SonosDevice? {
        let url = URL(string: "http://\(ip):1400/xml/device_description.xml")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            return parseDeviceDescription(data: data, ip: ip)
        } catch {
            log.debug("Probe failed for \(ip): \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse the Sonos device description XML to extract UUID and friendly name.
    private nonisolated func parseDeviceDescription(data: Data, ip: String) -> SonosDevice? {
        let parser = DeviceDescriptionParser(data: data)
        guard let result = parser.parse() else { return nil }
        return SonosDevice(
            uuid: result.uuid,
            roomName: result.roomName,
            ip: ip,
            isCoordinator: false,
            groupId: nil
        )
    }

    // MARK: - SSDP Discovery

    private func startSSDPDiscovery() {
        log.info("Starting SSDP discovery for Sonos speakers")

        // Listen for new UPnP devices from the registry
        UPnPRegistry.shared.deviceAdded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                self?.handleDiscoveredUPnPDevice(device)
            }
            .store(in: &cancellables)

        // Start discovery filtering for Sonos ZonePlayers
        try? UPnPRegistry.shared.startDiscovery([Self.sonosDeviceType])
    }

    private func handleDiscoveredUPnPDevice(_ device: UPnPDevice) {
        guard let definition = device.deviceDefinition?.device else { return }

        // Extract IP from the device's URL (url is non-optional on UPnPDevice)
        let host = device.url.host ?? "unknown"

        // UDN is uppercase in SwiftUPnP's Device model
        let uuid = definition.UDN.replacingOccurrences(of: "uuid:", with: "")

        // Store the UPnP device reference (needed for event subscriptions + SOAP control)
        upnpDevices[uuid] = device

        // If we already have this speaker from cache probe with a proper room name,
        // keep it — don't overwrite with UPnP's friendlyName (which is technical,
        // e.g., "192.168.1.214 - Sonos Amp" instead of "Study Sonos").
        // Re-publish speakers so AppState's trySubscribeToActiveZone() can pick up
        // the now-available UPnP device.
        if let existing = speakers.first(where: { $0.uuid == uuid }) {
            log.info("SSDP discovered: \(host) (already known as \(existing.roomName))")
            addOrUpdateSpeaker(existing)
            return
        }

        // New speaker not in cache — fetch the Sonos room name from device XML
        Task {
            if let probed = await probeIP(host, knownUUID: uuid, knownName: nil) {
                addOrUpdateSpeaker(probed)
                log.info("SSDP discovered: \(probed.roomName) at \(host)")
            } else {
                // Fallback to UPnP friendlyName if XML parse fails
                let sonosDevice = SonosDevice(
                    uuid: uuid,
                    roomName: definition.friendlyName,
                    ip: host,
                    isCoordinator: false,
                    groupId: nil
                )
                addOrUpdateSpeaker(sonosDevice)
                log.info("SSDP discovered: \(definition.friendlyName) at \(host)")
            }
        }
    }

    // MARK: - Direct UPnP Device Loading

    /// Load a UPnP device directly from a speaker IP, bypassing SSDP.
    ///
    /// Creates a `UPnPDevice` from the device description URL and feeds it to
    /// the shared registry, which loads root XML, creates typed services (AVTransport,
    /// RenderingControl, etc.), and fires `deviceAddedSubject`. Our existing
    /// `handleDiscoveredUPnPDevice` then picks it up and triggers event subscription.
    ///
    /// This is the fallback when SSDP multicast discovery doesn't find the speaker
    /// (common on some Sonos devices / network configurations).
    func loadUPnPDeviceDirectly(ip: String, uuid: String) {
        guard upnpDevices[uuid] == nil else { return }

        log.info("Loading UPnP device directly for \(uuid) at \(ip)")

        let descURL = URL(string: "http://\(ip):1400/xml/device_description.xml")!
        let description = UPnPDeviceDescription(
            uuid: "uuid:\(uuid)",
            deviceId: Self.sonosDeviceType,
            deviceType: Self.sonosDeviceType,
            url: descURL,
            lastSeen: Date()
        )

        guard let data = try? JSONEncoder().encode(description),
              let device = UPnPDevice.reanimate(from: data) else {
            log.error("Failed to create UPnP device description for \(uuid)")
            return
        }

        // Registry.add() is async internally: loads root XML → creates services →
        // fires deviceAddedSubject → our handleDiscoveredUPnPDevice picks it up.
        UPnPRegistry.shared.add(device)
    }

    // MARK: - Speaker Management

    private func addOrUpdateSpeaker(_ device: SonosDevice) {
        if let index = speakers.firstIndex(where: { $0.uuid == device.uuid }) {
            speakers[index] = device
        } else {
            speakers.append(device)
        }

        // Persist to cache for fast reconnection
        speakerStore.cacheSpeaker(device)
    }

    // MARK: - Network & Wake Monitoring

    private var lastNetworkPath: NWPath?

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Skip the initial firing — NWPathMonitor always fires once immediately.
                // Only act on actual network changes after the first path is stored.
                if let lastPath = self.lastNetworkPath {
                    // Only re-discover if the path actually changed
                    // (e.g., switched Wi-Fi networks, IP changed)
                    if lastPath != path {
                        log.info("Network change detected — re-discovering speakers")
                        self.speakers.removeAll()
                        self.upnpDevices.removeAll()
                        self.startDiscovery()
                    }
                }
                self.lastNetworkPath = path
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func setupWakeObserver() {
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Re-posted to main actor to satisfy strict concurrency.
            // The notification is observed on .main queue, and the Task
            // dispatches back to @MainActor for property access.
            Task { @MainActor [weak self] in
                log.info("System wake — re-discovering speakers")
                self?.speakers.removeAll()
                self?.upnpDevices.removeAll()
                self?.startDiscovery()
            }
        }
        workspaceObservers.append(observer)
    }
}

// MARK: - Device Description XML Parser

/// Minimal XML parser to extract UUID and room name from Sonos device description.
private class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    struct Result {
        let uuid: String
        let roomName: String
    }

    private let data: Data
    private var currentElement = ""
    private var uuid: String?
    private var roomName: String?
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> Result? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(),
              let uuid, let roomName else { return nil }
        return Result(uuid: uuid, roomName: roomName)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = element
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "UDN":
            // Only capture the first UDN (root device) — embedded devices
            // (MediaRenderer, MediaServer) have different UDNs with suffixes.
            if uuid == nil {
                uuid = text.replacingOccurrences(of: "uuid:", with: "")
            }
        case "roomName":
            if roomName == nil {
                roomName = text
            }
        default:
            break
        }
    }
}
