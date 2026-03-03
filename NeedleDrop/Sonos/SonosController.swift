import Foundation
import os
import SwiftUPnP

private let log = Logger(subsystem: "com.needledrop", category: "SonosController")

/// Sends SOAP control commands to Sonos speakers via SwiftUPnP.
///
/// All actions target the group coordinator. Commands are sent via the UPnP
/// AVTransport and RenderingControl services.
@MainActor
final class SonosController {

    // MARK: - Service Lookup

    /// Find AVTransport1Service on a UPnP device, waiting for services to load if needed.
    private func avTransport(for device: UPnPDevice) async -> AVTransport1Service? {
        for attempt in 1...5 {
            if let service = device.services.first(where: {
                $0.serviceType == "urn:schemas-upnp-org:service:AVTransport:1"
            }) as? AVTransport1Service {
                return service
            }
            if attempt < 5 {
                log.debug("AVTransport not ready on \(device.uuid), retry \(attempt)/5")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    /// Find RenderingControl1Service on a UPnP device, waiting for services to load if needed.
    private func renderingControl(for device: UPnPDevice) async -> RenderingControl1Service? {
        for attempt in 1...5 {
            if let service = device.services.first(where: {
                $0.serviceType == "urn:schemas-upnp-org:service:RenderingControl:1"
            }) as? RenderingControl1Service {
                return service
            }
            if attempt < 5 {
                log.debug("RenderingControl not ready on \(device.uuid), retry \(attempt)/5")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    // MARK: - Transport Controls

    /// Start or resume playback.
    func play(device: UPnPDevice) async {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return
        }
        do {
            try await service.play(instanceID: 0, speed: .one)
            log.debug("Play sent")
        } catch {
            log.error("Play failed: \(error.localizedDescription)")
        }
    }

    /// Pause playback.
    func pause(device: UPnPDevice) async {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return
        }
        do {
            try await service.pause(instanceID: 0)
            log.debug("Pause sent")
        } catch {
            log.error("Pause failed: \(error.localizedDescription)")
        }
    }

    /// Stop playback.
    func stop(device: UPnPDevice) async {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return
        }
        do {
            try await service.stop(instanceID: 0)
            log.debug("Stop sent")
        } catch {
            log.error("Stop failed: \(error.localizedDescription)")
        }
    }

    /// Skip to the next track.
    func next(device: UPnPDevice) async {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return
        }
        do {
            try await service.next(instanceID: 0)
            log.debug("Next sent")
        } catch {
            log.error("Next failed: \(error.localizedDescription)")
        }
    }

    /// Skip to the previous track.
    func previous(device: UPnPDevice) async {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return
        }
        do {
            try await service.previous(instanceID: 0)
            log.debug("Previous sent")
        } catch {
            log.error("Previous failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Volume

    /// Get the current volume level (0–100).
    func getVolume(device: UPnPDevice) async -> Int? {
        guard let service = await renderingControl(for: device) else {
            log.error("No RenderingControl service on device \(device.uuid)")
            return nil
        }
        do {
            let response = try await service.getVolume(instanceID: 0, channel: .master)
            return Int(response.currentVolume)
        } catch {
            log.error("GetVolume failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Set the volume level (0–100).
    func setVolume(device: UPnPDevice, level: Int) async {
        guard let service = await renderingControl(for: device) else {
            log.error("No RenderingControl service on device \(device.uuid)")
            return
        }
        let clamped = UInt16(min(max(level, 0), 100))
        do {
            try await service.setVolume(instanceID: 0, channel: .master, desiredVolume: clamped)
            log.debug("Volume set to \(clamped)")
        } catch {
            log.error("SetVolume failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Mute

    /// Get the current mute state.
    func getMute(device: UPnPDevice) async -> Bool? {
        guard let service = await renderingControl(for: device) else {
            log.error("No RenderingControl service on device \(device.uuid)")
            return nil
        }
        do {
            let response = try await service.getMute(instanceID: 0, channel: .master)
            return response.currentMute
        } catch {
            log.error("GetMute failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Set the mute state.
    func setMute(device: UPnPDevice, muted: Bool) async {
        guard let service = await renderingControl(for: device) else {
            log.error("No RenderingControl service on device \(device.uuid)")
            return
        }
        do {
            try await service.setMute(instanceID: 0, channel: .master, desiredMute: muted)
            log.debug("Mute set to \(muted)")
        } catch {
            log.error("SetMute failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Position Info

    /// Get the current playback position and track duration.
    /// Returns (positionSeconds, durationSeconds), or nil on failure.
    func getPositionInfo(device: UPnPDevice) async -> (position: Int, duration: Int)? {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return nil
        }
        do {
            let response = try await service.getPositionInfo(instanceID: 0)
            let position = Self.parseDuration(response.relTime)
            let duration = Self.parseDuration(response.trackDuration)
            return (position, duration)
        } catch {
            log.error("GetPositionInfo failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse "H:MM:SS" or "MM:SS" duration string to seconds.
    private static func parseDuration(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }

    // MARK: - Play URI

    /// Set the transport URI and start playback (used for favorites).
    ///
    /// - Parameters:
    ///   - device: The group coordinator to control.
    ///   - uri: The Sonos transport URI (e.g. `x-sonosapi-radio:...`, `x-rincon-cpcontainer:...`).
    ///   - metadata: DIDL-Lite XML metadata for the URI. Pass empty string if none.
    func playURI(device: UPnPDevice, uri: String, metadata: String = "") async {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return
        }
        do {
            try await service.setAVTransportURI(instanceID: 0, currentURI: uri, currentURIMetaData: metadata)
            try await service.play(instanceID: 0, speed: .one)
            log.info("Playing URI: \(uri)")
        } catch {
            log.error("PlayURI failed: \(error.localizedDescription)")
        }
    }
}
