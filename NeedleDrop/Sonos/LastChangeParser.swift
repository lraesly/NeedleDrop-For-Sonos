import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "LastChangeParser")

/// Parsed result from an AVTransport LastChange XML event.
struct LastChangeEvent: Equatable {
    var transportState: String?
    var currentTrackMetaData: String?   // Raw DIDL-Lite XML (unescaped)
    var currentTrackDuration: String?   // "H:MM:SS" or "MM:SS"
    var avTransportURI: String?
    var enqueuedTransportURI: String?
}

/// Parses the LastChange XML from AVTransport UPnP events.
///
/// The LastChange XML has this structure:
/// ```xml
/// <Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">
///   <InstanceID val="0">
///     <TransportState val="PLAYING"/>
///     <CurrentTrackMetaData val="&lt;DIDL-Lite...&gt;"/>
///     <CurrentTrackDuration val="0:03:45"/>
///     <AVTransportURI val="..."/>
///     <EnqueuedTransportURI val="..."/>
///   </InstanceID>
/// </Event>
/// ```
///
/// The `val` attributes contain the actual values. The `CurrentTrackMetaData`
/// value is XML-escaped DIDL-Lite that the caller should parse separately.
final class LastChangeParser: NSObject, XMLParserDelegate {

    private var result = LastChangeEvent()
    private var parseError = false

    /// Parse a LastChange XML string into a structured event.
    static func parse(_ xml: String) -> LastChangeEvent? {
        guard let data = xml.data(using: .utf8) else {
            log.error("LastChange XML is not valid UTF-8")
            return nil
        }

        let handler = LastChangeParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.shouldProcessNamespaces = false

        guard parser.parse(), !handler.parseError else {
            log.error("Failed to parse LastChange XML")
            return nil
        }

        return handler.result
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard let val = attributes["val"] else { return }

        switch element {
        case "TransportState":
            result.transportState = val
        case "CurrentTrackMetaData":
            // val is XML-escaped DIDL-Lite — XMLParser already unescaped it
            result.currentTrackMetaData = val.isEmpty ? nil : val
        case "CurrentTrackDuration":
            result.currentTrackDuration = val
        case "AVTransportURI":
            result.avTransportURI = val.isEmpty ? nil : val
        case "EnqueuedTransportURI":
            result.enqueuedTransportURI = val.isEmpty ? nil : val
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        log.debug("LastChange parse error: \(error.localizedDescription)")
        parseError = true
    }
}

// MARK: - Duration Parsing

extension LastChangeEvent {
    /// Parse the duration string ("H:MM:SS" or "MM:SS") into seconds.
    /// Returns 0 if the string can't be parsed.
    var durationSeconds: Int {
        guard let duration = currentTrackDuration, duration.contains(":") else { return 0 }
        return Self.parseDuration(duration)
    }

    /// Parse "H:MM:SS" or "MM:SS" into total seconds.
    static func parseDuration(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }
}
