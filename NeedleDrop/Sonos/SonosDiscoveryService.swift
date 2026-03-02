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
        let roomName = definition.friendlyName

        let sonosDevice = SonosDevice(
            uuid: uuid,
            roomName: roomName,
            ip: host,
            isCoordinator: false,
            groupId: nil
        )

        log.info("SSDP discovered: \(roomName) at \(host)")
        upnpDevices[uuid] = device
        addOrUpdateSpeaker(sonosDevice)
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

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            log.info("Network change detected — re-discovering speakers")
            Task { @MainActor [weak self] in
                self?.speakers.removeAll()
                self?.upnpDevices.removeAll()
                self?.startDiscovery()
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
        ) { [weak self] _ in
            log.info("System wake — re-discovering speakers")
            self?.speakers.removeAll()
            self?.upnpDevices.removeAll()
            self?.startDiscovery()
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
            uuid = text.replacingOccurrences(of: "uuid:", with: "")
        case "roomName":
            roomName = text
        default:
            break
        }
    }
}
