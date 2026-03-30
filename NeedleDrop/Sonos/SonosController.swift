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

    // MARK: - Volume by IP (direct SOAP, bypasses UPnP device lookup)

    /// Get volume via direct SOAP call to speaker IP. Works for all speakers
    /// including those not yet discovered via SSDP (e.g. grouped members from topology).
    nonisolated func getVolumeByIP(_ ip: String) async -> Int? {
        let url = URL(string: "http://\(ip):1400/MediaRenderer/RenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#GetVolume\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                </u:GetVolume>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let body = String(data: data, encoding: .utf8),
                  let range = body.range(of: "(?<=<CurrentVolume>)\\d+", options: .regularExpression) else {
                return nil
            }
            return Int(body[range])
        } catch {
            log.debug("GetVolume SOAP failed for \(ip): \(error.localizedDescription)")
            return nil
        }
    }

    /// Set volume via direct SOAP call to speaker IP.
    /// Returns true on success, false on failure.
    /// [Audit fix #1/#3: return Bool so callers can detect and handle failures]
    @discardableResult
    nonisolated func setVolumeByIP(_ ip: String, level: Int) async -> Bool {
        let clamped = min(max(level, 0), 100)
        let url = URL(string: "http://\(ip):1400/MediaRenderer/RenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                  <DesiredVolume>\(clamped)</DesiredVolume>
                </u:SetVolume>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.debug("SetVolume SOAP failed for \(ip): bad status")
                return false
            }
            log.debug("Volume set to \(clamped) on \(ip)")
            return true
        } catch {
            log.debug("SetVolume SOAP failed for \(ip): \(error.localizedDescription)")
            return false
        }
    }

    /// Play a URI via direct SOAP call to speaker IP (bypasses UPnP device registry).
    /// Returns true on success, false on failure.
    /// [Audit fix #1: return Bool so callers can detect playback failures]
    @discardableResult
    nonisolated func playURIByIP(_ ip: String, uri: String, metadata: String = "") async -> Bool {
        let endpoint = URL(string: "http://\(ip):1400/MediaRenderer/AVTransport/Control")!

        // XML-escape both URI and metadata for safe embedding in SOAP XML.
        // Metadata is DIDL-Lite XML that must be escaped as a text node.
        let escapedURI = Self.xmlEscape(uri)
        let escapedMeta = Self.xmlEscape(metadata)

        // 1. SetAVTransportURI
        var setReq = URLRequest(url: endpoint)
        setReq.httpMethod = "POST"
        setReq.timeoutInterval = 5
        setReq.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        setReq.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"", forHTTPHeaderField: "SOAPAction")
        setReq.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                  <InstanceID>0</InstanceID>
                  <CurrentURI>\(escapedURI)</CurrentURI>
                  <CurrentURIMetaData>\(escapedMeta)</CurrentURIMetaData>
                </u:SetAVTransportURI>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (data, setResponse) = try await URLSession.shared.data(for: setReq)
            guard let httpSetResponse = setResponse as? HTTPURLResponse,
                  httpSetResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                log.error("SetAVTransportURI SOAP failed for \(ip): status \((setResponse as? HTTPURLResponse)?.statusCode ?? -1) — \(body)")
                return false
            }
        } catch {
            log.error("SetAVTransportURI SOAP failed for \(ip): \(error.localizedDescription)")
            return false
        }

        // 2. Play
        var playReq = URLRequest(url: endpoint)
        playReq.httpMethod = "POST"
        playReq.timeoutInterval = 5
        playReq.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        playReq.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#Play\"", forHTTPHeaderField: "SOAPAction")
        playReq.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                  <InstanceID>0</InstanceID>
                  <Speed>1</Speed>
                </u:Play>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (_, playResponse) = try await URLSession.shared.data(for: playReq)
            guard let httpPlayResponse = playResponse as? HTTPURLResponse,
                  httpPlayResponse.statusCode == 200 else {
                log.error("Play SOAP failed for \(ip): bad status")
                return false
            }
            log.info("Playing URI via direct SOAP on \(ip): \(uri.prefix(60))")
            return true
        } catch {
            log.error("Play SOAP failed for \(ip): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Direct SOAP Transport Controls

    /// Send a simple AVTransport action via direct SOAP to speaker IP.
    /// Works for Play, Pause, Stop, Next, Previous — any action with no extra parameters.
    @discardableResult
    nonisolated func avTransportActionByIP(_ ip: String, action: String, extraBody: String = "") async -> Bool {
        let url = URL(string: "http://\(ip):1400/MediaRenderer/AVTransport/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                  <InstanceID>0</InstanceID>\(extraBody)
                </u:\(action)>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("\(action) SOAP failed for \(ip): bad status")
                return false
            }
            log.debug("\(action) sent to \(ip)")
            return true
        } catch {
            log.error("\(action) SOAP failed for \(ip): \(error.localizedDescription)")
            return false
        }
    }

    /// Resume playback via direct SOAP.
    @discardableResult
    nonisolated func playByIP(_ ip: String) async -> Bool {
        await avTransportActionByIP(ip, action: "Play", extraBody: "<Speed>1</Speed>")
    }

    /// Pause playback via direct SOAP.
    @discardableResult
    nonisolated func pauseByIP(_ ip: String) async -> Bool {
        await avTransportActionByIP(ip, action: "Pause")
    }

    /// Skip to next track via direct SOAP.
    @discardableResult
    nonisolated func nextByIP(_ ip: String) async -> Bool {
        await avTransportActionByIP(ip, action: "Next")
    }

    /// Skip to previous track via direct SOAP.
    @discardableResult
    nonisolated func previousByIP(_ ip: String) async -> Bool {
        await avTransportActionByIP(ip, action: "Previous")
    }

    /// Set mute state via direct SOAP.
    @discardableResult
    nonisolated func setMuteByIP(_ ip: String, muted: Bool) async -> Bool {
        let url = URL(string: "http://\(ip):1400/MediaRenderer/RenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                  <DesiredMute>\(muted ? 1 : 0)</DesiredMute>
                </u:SetMute>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("SetMute SOAP failed for \(ip): bad status")
                return false
            }
            log.debug("Mute set to \(muted) on \(ip)")
            return true
        } catch {
            log.error("SetMute SOAP failed for \(ip): \(error.localizedDescription)")
            return false
        }
    }

    /// Get the current mute state via direct SOAP.
    nonisolated func getMuteByIP(_ ip: String) async -> Bool? {
        let url = URL(string: "http://\(ip):1400/MediaRenderer/RenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#GetMute\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:GetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                  <InstanceID>0</InstanceID>
                  <Channel>Master</Channel>
                </u:GetMute>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let body = String(data: data, encoding: .utf8),
                  let range = body.range(of: "(?<=<CurrentMute>)[01]", options: .regularExpression) else {
                return nil
            }
            return body[range] == "1"
        } catch {
            log.debug("GetMute SOAP failed for \(ip): \(error.localizedDescription)")
            return nil
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

    /// Result of a GetPositionInfo SOAP query.
    struct PositionInfo {
        var position: Int
        var duration: Int
        /// Raw DIDL-Lite XML for the current track (may be empty during station breaks).
        var trackMetaData: String
    }

    /// Get the current playback position, track duration, and raw track metadata.
    /// Returns nil on failure (network error, malformed SOAP response).
    func getPositionInfo(device: UPnPDevice) async -> PositionInfo? {
        guard let service = await avTransport(for: device) else {
            log.error("No AVTransport service on device \(device.uuid)")
            return nil
        }
        do {
            let response = try await service.getPositionInfo(instanceID: 0)
            let position = Self.parseDuration(response.relTime)
            let duration = Self.parseDuration(response.trackDuration)
            return PositionInfo(
                position: position,
                duration: duration,
                trackMetaData: response.trackMetaData
            )
        } catch {
            log.debug("GetPositionInfo failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// XML-escape a string for safe embedding in SOAP XML bodies.
    private nonisolated static func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Parse "H:MM:SS" or "MM:SS" duration string to seconds.
    private nonisolated static func parseDuration(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }

    /// Get the current playback position and track duration via direct SOAP call.
    /// Bypasses UPnP device registry — works even when SSDP hasn't (re)discovered the speaker.
    nonisolated func getPositionInfoByIP(_ ip: String) async -> PositionInfo? {
        let url = URL(string: "http://\(ip):1400/MediaRenderer/AVTransport/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                  <InstanceID>0</InstanceID>
                </u:GetPositionInfo>
              </s:Body>
            </s:Envelope>
            """.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let body = String(data: data, encoding: .utf8) else {
                return nil
            }

            let position = Self.extractDuration(from: body, element: "RelTime")
            let duration = Self.extractDuration(from: body, element: "TrackDuration")

            // Extract TrackMetaData (DIDL-Lite XML, may be HTML-encoded in SOAP response)
            var trackMetaData = ""
            if let startRange = body.range(of: "<TrackMetaData>"),
               let endRange = body.range(of: "</TrackMetaData>") {
                let encoded = String(body[startRange.upperBound..<endRange.lowerBound])
                trackMetaData = encoded
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&apos;", with: "'")
            }

            return PositionInfo(position: position, duration: duration, trackMetaData: trackMetaData)
        } catch {
            log.debug("GetPositionInfo SOAP failed for \(ip): \(error.localizedDescription)")
            return nil
        }
    }

    /// Extract a duration value (H:MM:SS) from a SOAP response element.
    private nonisolated static func extractDuration(from body: String, element: String) -> Int {
        let pattern = "(?<=<\(element)>)[^<]+"
        guard let range = body.range(of: pattern, options: .regularExpression) else { return 0 }
        return parseDuration(String(body[range]))
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
