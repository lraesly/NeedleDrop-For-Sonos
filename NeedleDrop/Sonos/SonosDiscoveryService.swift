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

    /// Set during system sleep to suppress network-change-triggered discovery.
    /// NWPathMonitor fires multiple rapid path changes as interfaces go down/up
    /// during sleep — probing cached IPs during sleep always times out.
    private var isSleeping = false

    /// Debounce task for network-change-triggered discovery. Coalesces rapid
    /// path changes (common during wake) into a single discovery cycle.
    private var networkChangeDebounceTask: Task<Void, Never>?

    /// The UPnP device type for Sonos ZonePlayers.
    private static let sonosDeviceType = "urn:schemas-upnp-org:device:ZonePlayer:1"

    init(speakerStore: SpeakerStore) {
        self.speakerStore = speakerStore
        setupNetworkMonitor()
        setupSleepWakeObservers()
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

        // Fast path: probe cached speaker IPs (filtered to current subnet)
        let cached = speakerStore.loadCachedSpeakers()
        let localSubnet = Self.currentSubnetPrefix()
        let filtered: [CachedSpeaker]
        if let localSubnet {
            filtered = cached.filter { $0.ip.hasPrefix(localSubnet) }
            let skipped = cached.count - filtered.count
            if skipped > 0 {
                log.info("Skipping \(skipped) cached speaker(s) on different subnet (current: \(localSubnet)*)")
            }
        } else {
            filtered = cached
        }
        if !filtered.isEmpty {
            log.info("Probing \(filtered.count) cached speaker IPs")
            Task {
                await probeCachedSpeakers(filtered)
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

    /// URLSession with a short overall timeout for probing cached speaker IPs.
    /// The default URLSession.shared uses a 60s resource timeout, which means
    /// probes to unreachable IPs (e.g., stale IPs from a different subnet)
    /// block for a long time. This session caps the entire request at 3 seconds.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    /// Try to reach a Sonos speaker at a known IP by fetching its device description.
    private nonisolated func probeIP(_ ip: String, knownUUID: String?, knownName: String?) async -> SonosDevice? {
        let url = URL(string: "http://\(ip):1400/xml/device_description.xml")!
        let request = URLRequest(url: url)

        do {
            let (data, response) = try await Self.probeSession.data(for: request)
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

    // MARK: - Subnet Helpers

    /// Returns the first three octets of the Mac's current local IP (e.g., "192.168.2.").
    /// Used to filter cached speaker probes to the current /24 subnet.
    private nonisolated static func currentSubnetPrefix() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // Skip loopback and non-Wi-Fi/Ethernet interfaces
            guard name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa.pointee.ifa_addr, socklen_t(ifa.pointee.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    return "\(parts[0]).\(parts[1]).\(parts[2])."
                }
            }
        }
        return nil
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
                        // During sleep, network interfaces go down/up causing rapid
                        // path changes. All probes will timeout — skip entirely.
                        guard !self.isSleeping else {
                            log.debug("Network change during sleep — skipping discovery")
                            self.lastNetworkPath = path
                            return
                        }

                        // Debounce: coalesce rapid post-wake path changes into
                        // a single discovery cycle (NWPathMonitor often fires
                        // 3-4 times in quick succession after wake).
                        self.networkChangeDebounceTask?.cancel()
                        self.networkChangeDebounceTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled, let self else { return }
                            log.info("Network change detected — re-discovering speakers")
                            self.speakers.removeAll()
                            self.upnpDevices.removeAll()
                            self.startDiscovery()
                        }
                    }
                }
                self.lastNetworkPath = path
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.isSleeping = true
                self?.networkChangeDebounceTask?.cancel()
                self?.networkChangeDebounceTask = nil
                log.debug("Discovery suppressed for sleep")
            }
        }
        workspaceObservers.append(sleepObserver)

        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSleeping = false
                log.info("System wake — re-discovering speakers")
                // Brief delay to let the network interface stabilize,
                // then do a single discovery. Any network-change events
                // that fire during this window are debounced above.
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self.speakers.removeAll()
                self.upnpDevices.removeAll()
                self.startDiscovery()
            }
        }
        workspaceObservers.append(wakeObserver)
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
