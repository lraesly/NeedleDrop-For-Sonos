import Foundation
import os
import SwiftUPnP

private let log = Logger(subsystem: "com.needledrop", category: "SonosZoneManager")

/// Manages Sonos zone topology, favorites, and speaker grouping.
///
/// Zone topology uses custom SOAP calls to ZoneGroupTopology (not in SwiftUPnP).
/// Favorites use SwiftUPnP's ContentDirectory1Service.browseDIDL().
/// Grouping uses AVTransport SetAVTransportURI with `x-rincon:` URIs.
@MainActor
final class SonosZoneManager {

    // MARK: - Zone Topology

    /// Fetch the zone group topology from any Sonos speaker on the network.
    ///
    /// Sends a SOAP request to ZoneGroupTopology/Control and parses the
    /// XML response into zone groups with coordinators and members.
    func getZoneGroups(speakerIP: String) async -> [SonosZoneGroup] {
        let url = URL(string: "http://\(speakerIP):1400/ZoneGroupTopology/Control")!

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("ZoneGroupTopology request failed")
                return []
            }

            let groups = ZoneGroupTopologyParser.parse(data)
            log.info("Found \(groups.count) zone group(s)")
            return groups
        } catch {
            log.error("ZoneGroupTopology request error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Favorites

    /// Fetch Sonos favorites via ContentDirectory Browse (ObjectID=FV:2).
    func getFavorites(device: UPnPDevice) async -> [FavoriteItem] {
        guard let service = device.services.first(where: {
            $0.serviceType == "urn:schemas-upnp-org:service:ContentDirectory:1"
        }) as? ContentDirectory1Service else {
            log.error("No ContentDirectory service on device \(device.uuid)")
            return []
        }

        do {
            let response = try await service.browseDIDL(
                objectID: "FV:2",
                browseFlag: .browseDirectChildren,
                filter: "*",
                startingIndex: 0,
                requestedCount: 100,
                sortCriteria: ""
            )

            let speakerIP = device.url.host ?? ""
            let favorites = response.item.compactMap { item -> FavoriteItem? in
                // Get playable URI from the res elements
                guard let uri = item.res.first?.value.absoluteString else { return nil }

                // Resolve album art URI
                let artURL: String?
                if let art = item.albumArtURI.first {
                    let artStr = art.absoluteString
                    if artStr.hasPrefix("http") {
                        artURL = artStr
                    } else {
                        artURL = "http://\(speakerIP):1400\(artStr)"
                    }
                } else {
                    artURL = nil
                }

                // Build the resource metadata XML for playback.
                // The desc element contains the DIDL metadata needed by SetAVTransportURI.
                let meta = item.desc.first?.value ?? ""

                return FavoriteItem(
                    title: item.title,
                    uri: uri,
                    meta: meta,
                    albumArtUri: artURL
                )
            }

            log.info("Fetched \(favorites.count) favorite(s)")
            return favorites
        } catch {
            log.error("Favorites browse failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Speaker Grouping

    /// Join a speaker to a coordinator's group.
    ///
    /// Sets the speaker's AVTransport URI to `x-rincon:{coordinatorUUID}`,
    /// which makes it play audio from the coordinator's group.
    func joinSpeaker(speaker: UPnPDevice, toCoordinator coordinator: SonosDevice) async {
        guard let service = speaker.services.first(where: {
            $0.serviceType == "urn:schemas-upnp-org:service:AVTransport:1"
        }) as? AVTransport1Service else {
            log.error("No AVTransport service on speaker")
            return
        }

        let rinconURI = "x-rincon:\(coordinator.uuid)"
        do {
            try await service.setAVTransportURI(
                instanceID: 0,
                currentURI: rinconURI,
                currentURIMetaData: ""
            )
            log.info("Joined speaker to \(coordinator.roomName)")
        } catch {
            log.error("Join failed: \(error.localizedDescription)")
        }
    }

    /// Remove a speaker from its group (make it standalone).
    ///
    /// Sends the BecomeCoordinatorOfStandaloneGroup SOAP action directly
    /// since SwiftUPnP doesn't expose this Sonos-specific action.
    func unjoinSpeaker(speakerIP: String) async {
        let url = URL(string: "http://\(speakerIP):1400/MediaRenderer/AVTransport/Control")!

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:BecomeCoordinatorOfStandaloneGroup xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:BecomeCoordinatorOfStandaloneGroup>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("Unjoin SOAP request failed")
                return
            }
            log.info("Speaker unjoined at \(speakerIP)")
        } catch {
            log.error("Unjoin failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ZoneGroupTopology XML Parser

/// Parses the ZoneGroupTopology SOAP response XML.
///
/// Expected structure (inside SOAP envelope):
/// ```xml
/// <ZoneGroupState>
///   <ZoneGroups>
///     <ZoneGroup Coordinator="RINCON_XXX" ID="...">
///       <ZoneGroupMember UUID="RINCON_XXX" ZoneName="Living Room"
///           Location="http://192.168.1.10:1400/xml/device_description.xml" .../>
///     </ZoneGroup>
///   </ZoneGroups>
/// </ZoneGroupState>
/// ```
private class ZoneGroupTopologyParser: NSObject, XMLParserDelegate {

    private var groups: [SonosZoneGroup] = []
    private var currentCoordinatorUUID: String?
    private var currentMembers: [SonosDevice] = []
    private var inZoneGroupState = false
    private var currentElement = ""
    private var currentText = ""

    static func parse(_ data: Data) -> [SonosZoneGroup] {
        // The ZoneGroupState XML is nested inside the SOAP response as an escaped string.
        // First extract it, then parse the inner XML.
        let outerParser = ZoneGroupStateExtractor(data: data)
        guard let zoneGroupStateXML = outerParser.extract() else {
            log.error("Could not extract ZoneGroupState from SOAP response")
            return []
        }

        guard let innerData = zoneGroupStateXML.data(using: .utf8) else { return [] }
        let parser = ZoneGroupTopologyParser()
        let xmlParser = XMLParser(data: innerData)
        xmlParser.delegate = parser
        xmlParser.shouldProcessNamespaces = false
        xmlParser.parse()
        return parser.groups
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = element

        if element == "ZoneGroup" {
            currentCoordinatorUUID = attributes["Coordinator"]
            currentMembers = []
        } else if element == "ZoneGroupMember" {
            guard let uuid = attributes["UUID"],
                  let zoneName = attributes["ZoneName"],
                  let location = attributes["Location"] else { return }

            // Extract IP from Location URL (e.g., "http://192.168.1.10:1400/xml/...")
            let ip = URL(string: location)?.host ?? ""

            let isCoordinator = uuid == currentCoordinatorUUID
            let device = SonosDevice(
                uuid: uuid,
                roomName: zoneName,
                ip: ip,
                isCoordinator: isCoordinator,
                groupId: nil
            )
            currentMembers.append(device)
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "ZoneGroup" {
            guard let coordUUID = currentCoordinatorUUID,
                  let coordinator = currentMembers.first(where: { $0.uuid == coordUUID }) else { return }

            let members = currentMembers.filter { $0.uuid != coordUUID }
            let group = SonosZoneGroup(coordinator: coordinator, members: members)
            groups.append(group)
        }
    }
}

/// Extracts the ZoneGroupState XML string from the SOAP response envelope.
/// The state is returned as text content of a <ZoneGroupState> element.
private class ZoneGroupStateExtractor: NSObject, XMLParserDelegate {
    private let data: Data
    private var currentElement = ""
    private var currentText = ""
    private var zoneGroupState: String?

    init(data: Data) {
        self.data = data
    }

    func extract() -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return zoneGroupState
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = element
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "ZoneGroupState" {
            zoneGroupState = currentText
        }
    }
}
