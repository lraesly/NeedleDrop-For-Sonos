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

    // MARK: - Household Identity

    /// Fetch the Sonos household ID from any speaker on the network.
    ///
    /// All speakers in the same Sonos system return the same household ID
    /// (e.g., `Sonos_asahHKgjgJGjgjGjggjJgjJG34`).  Stable across reboots,
    /// speaker additions/removals, and network changes.
    func getHouseholdID(speakerIP: String) async -> String? {
        let url = URL(string: "http://\(speakerIP):1400/DeviceProperties/Control")!

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetHouseholdID xmlns:u="urn:schemas-upnp-org:service:DeviceProperties:1"/>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:DeviceProperties:1#GetHouseholdID\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("GetHouseholdID request failed for \(speakerIP)")
                return nil
            }

            let extractor = SOAPElementExtractor(data: data, elementName: "CurrentHouseholdID")
            let householdId = extractor.extract()?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = householdId {
                log.info("Household ID: \(id)")
            }
            return householdId
        } catch {
            log.error("GetHouseholdID failed for \(speakerIP): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Transport Info

    /// Query the current transport state of a zone coordinator.
    ///
    /// Sends a GetTransportInfo SOAP request to the speaker's AVTransport service.
    /// Returns the transport state string (e.g. "PLAYING", "PAUSED_PLAYBACK", "STOPPED").
    func getTransportState(speakerIP: String) async -> String? {
        let url = URL(string: "http://\(speakerIP):1400/MediaRenderer/AVTransport/Control")!

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetTransportInfo>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Parse <CurrentTransportState> from the SOAP response
            let parser = TransportInfoParser(data: data)
            return parser.parse()
        } catch {
            log.debug("GetTransportInfo failed for \(speakerIP): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Favorites

    /// Fetch Sonos favorites via raw SOAP Browse (ObjectID=FV:2).
    ///
    /// Uses direct SOAP instead of SwiftUPnP's ContentDirectory service
    /// to avoid dependency on UPnP device loading.
    func getFavorites(speakerIP: String) async -> [FavoriteItem] {
        let url = URL(string: "http://\(speakerIP):1400/MediaServer/ContentDirectory/Control")!

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>FV:2</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>0</StartingIndex>
              <RequestedCount>100</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("Favorites browse request failed")
                return []
            }

            // Extract the <Result> element from the SOAP response
            let extractor = SOAPElementExtractor(data: data, elementName: "Result")
            guard let didlXML = extractor.extract(), !didlXML.isEmpty else {
                log.error("No Result element in favorites browse response")
                return []
            }

            // Parse the DIDL-Lite XML into favorites
            let favorites = FavoritesDIDLParser.parse(didlXML, speakerIP: speakerIP)
            log.info("Fetched \(favorites.count) favorite(s)")
            return favorites
        } catch {
            log.error("Favorites browse failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Speaker Grouping

    /// Join a speaker to a coordinator's group using direct SOAP.
    ///
    /// Sets the speaker's AVTransport URI to `x-rincon:{coordinatorUUID}`,
    /// which makes it play audio from the coordinator's group.
    /// Uses SOAP directly so it works regardless of SSDP discovery state.
    /// Returns true on success, false on failure.
    /// [Audit fix #1: return Bool so callers can detect grouping failures]
    @discardableResult
    func joinSpeaker(speakerIP: String, toCoordinatorUUID coordinatorUUID: String) async -> Bool {
        let url = URL(string: "http://\(speakerIP):1400/MediaRenderer/AVTransport/Control")!
        let rinconURI = "x-rincon:\(coordinatorUUID)"

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
            xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>\(rinconURI)</CurrentURI>
              <CurrentURIMetaData></CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("Join SOAP request failed for \(speakerIP)")
                return false
            }
            log.info("Joined speaker at \(speakerIP) to coordinator \(coordinatorUUID)")
            return true
        } catch {
            log.error("Join failed for \(speakerIP): \(error.localizedDescription)")
            return false
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
        } else if element == "ZoneGroupMember" || element == "Satellite" {
            guard let uuid = attributes["UUID"],
                  let zoneName = attributes["ZoneName"],
                  let location = attributes["Location"] else { return }

            // Skip invisible/bonded speakers (Sub, surround speakers, etc.)
            // These can't be independently grouped.
            if attributes["Invisible"] == "1" || element == "Satellite" {
                return
            }

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

/// Parses the GetTransportInfo SOAP response to extract CurrentTransportState.
private class TransportInfoParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var currentElement = ""
    private var currentText = ""
    private var transportState: String?

    init(data: Data) {
        self.data = data
    }

    func parse() -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return transportState
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
        if element == "CurrentTransportState" {
            transportState = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Extracts a single named element's text content from a SOAP response.
private class SOAPElementExtractor: NSObject, XMLParserDelegate {
    private let data: Data
    private let elementName: String
    private var currentElement = ""
    private var currentText = ""
    private var result: String?

    init(data: Data, elementName: String) {
        self.data = data
        self.elementName = elementName
    }

    func extract() -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = element
        if element == elementName { currentText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == elementName { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == elementName {
            result = currentText
        }
    }
}

/// Parses DIDL-Lite XML from a ContentDirectory Browse response into FavoriteItem array.
///
/// Each `<item>` contains:
/// - `<dc:title>` — display title
/// - `<res>` — playable URI
/// - `<r:resMD>` — metadata XML for SetAVTransportURI
/// - `<upnp:albumArtURI>` — album art (may be relative)
private class FavoritesDIDLParser: NSObject, XMLParserDelegate {
    private var favorites: [FavoriteItem] = []
    private var speakerIP: String
    private var inItem = false
    private var currentElement = ""
    private var currentText = ""

    // Per-item state
    private var itemTitle = ""
    private var itemURI = ""
    private var itemMeta = ""
    private var itemArtURI: String?

    init(speakerIP: String) {
        self.speakerIP = speakerIP
    }

    static func parse(_ xml: String, speakerIP: String) -> [FavoriteItem] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let handler = FavoritesDIDLParser(speakerIP: speakerIP)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.shouldProcessNamespaces = true
        parser.parse()
        return handler.favorites
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if element == "item" {
            inItem = true
            itemTitle = ""
            itemURI = ""
            itemMeta = ""
            itemArtURI = nil
        }
        currentElement = element
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "title":
            if !text.isEmpty { itemTitle = text }
        case "res":
            if !text.isEmpty && itemURI.isEmpty { itemURI = text }
        case "resMD":
            if !text.isEmpty { itemMeta = text }
        case "albumArtURI":
            if !text.isEmpty { itemArtURI = text }
        case "item":
            // End of item — emit favorite if we have title + URI
            if !itemTitle.isEmpty && !itemURI.isEmpty {
                // Resolve album art URI
                var resolvedArt: String?
                if let art = itemArtURI {
                    if art.hasPrefix("http") {
                        resolvedArt = art
                    } else {
                        resolvedArt = "http://\(speakerIP):1400\(art.hasPrefix("/") ? art : "/\(art)")"
                    }
                }

                favorites.append(FavoriteItem(
                    title: itemTitle,
                    uri: itemURI,
                    meta: itemMeta,
                    albumArtUri: resolvedArt
                ))
            }
            inItem = false
        default:
            break
        }
    }
}
