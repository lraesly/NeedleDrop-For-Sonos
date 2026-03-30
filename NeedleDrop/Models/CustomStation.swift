import Foundation

struct CustomStation: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var streamURL: String
    var artURL: String?

    init(id: UUID = UUID(), name: String, streamURL: String, artURL: String? = nil) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.artURL = artURL
    }

    /// The stream URL converted to a Sonos-compatible `x-rincon-mp3radio://` URI.
    /// Sonos rejects raw http/https URIs (error 714); this scheme tells it to
    /// fetch the URL as an audio stream.
    var sonosURI: String {
        var url = streamURL
        if url.hasPrefix("https://") {
            url = String(url.dropFirst("https://".count))
        } else if url.hasPrefix("http://") {
            url = String(url.dropFirst("http://".count))
        }
        return "x-rincon-mp3radio://\(url)"
    }

    /// Minimal DIDL-Lite metadata so Sonos displays the station name.
    var sonosMetadata: String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="R:0/0/0" parentID="R:0/0" restricted="true">\
        <dc:title>\(xmlEscapedName)</dc:title>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
        \(artMetadataFragment)\
        </item></DIDL-Lite>
        """
    }

    /// Convert to a FavoriteItem so custom stations can be used in preset/schedule pickers.
    var asFavoriteItem: FavoriteItem {
        FavoriteItem(title: name, uri: sonosURI, meta: sonosMetadata, albumArtUri: artURL)
    }

    private var artMetadataFragment: String {
        guard let art = artURL, !art.isEmpty else { return "" }
        let escaped = art.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<upnp:albumArtURI>\(escaped)</upnp:albumArtURI>"
    }

    private var xmlEscapedName: String {
        name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
