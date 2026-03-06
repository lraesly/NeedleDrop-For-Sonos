import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "DIDLLiteParser")

/// Parsed metadata from a DIDL-Lite XML fragment.
struct DIDLLiteMetadata: Equatable {
    var title: String?
    var creator: String?          // dc:creator (artist)
    var album: String?            // upnp:album
    var albumArtURI: String?      // upnp:albumArtURI (may be relative)
    var streamContent: String?    // r:streamContent (radio metadata)
    var radioShowMd: String?      // r:radioShowMd
}

/// Parses DIDL-Lite XML metadata from Sonos track events.
///
/// DIDL-Lite structure:
/// ```xml
/// <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"
///            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
///            xmlns:r="urn:schemas-rincon-com:metadata-1-0/"
///            xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
///   <item>
///     <dc:title>Song Title</dc:title>
///     <dc:creator>Artist Name</dc:creator>
///     <upnp:album>Album Name</upnp:album>
///     <upnp:albumArtURI>/getaa?s=1&amp;u=...</upnp:albumArtURI>
///     <r:streamContent>TYPE=SNG|TITLE ...|ARTIST ...</r:streamContent>
///   </item>
/// </DIDL-Lite>
/// ```
final class DIDLLiteParser: NSObject, XMLParserDelegate {

    private var result = DIDLLiteMetadata()
    private var currentElement = ""
    private var currentText = ""
    private var parseError = false

    /// Parse a DIDL-Lite XML string into structured metadata.
    static func parse(_ xml: String) -> DIDLLiteMetadata? {
        guard let data = xml.data(using: .utf8) else {
            log.error("DIDL-Lite XML is not valid UTF-8")
            return nil
        }

        let handler = DIDLLiteParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        // Process namespaces so we get local names like "title" not "dc:title"
        parser.shouldProcessNamespaces = true

        guard parser.parse(), !handler.parseError else {
            log.debug("Failed to parse DIDL-Lite XML")
            return nil
        }

        return handler.result
    }

    // MARK: - XMLParserDelegate

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
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch element {
        case "title":
            result.title = text
        case "creator":
            result.creator = text
        case "album":
            result.album = text
        case "albumArtURI":
            result.albumArtURI = text
        case "streamContent":
            result.streamContent = text
        case "radioShowMd":
            result.radioShowMd = text
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        log.debug("DIDL-Lite parse error: \(error.localizedDescription)")
        parseError = true
    }
}

// MARK: - Stream Content Parsing

extension DIDLLiteMetadata {
    /// Parse the `r:streamContent` field for artist/title info.
    ///
    /// Handles two formats:
    /// 1. SiriusXM pipe-delimited: `"TYPE=SNG|TITLE Song Name|ARTIST Artist Name|ALBUM Album"`
    /// 2. Simple radio: `"Artist - Title"`
    ///
    /// The `type` field captures the SiriusXM TYPE value (e.g., "SNG" for songs).
    /// Non-song types (DJ segments, ads) should be treated differently by callers.
    struct StreamContentInfo: Equatable {
        var artist: String?
        var title: String?
        var album: String?
        /// SiriusXM stream content type: "SNG" = song, anything else = non-music (DJ, ad, etc.).
        /// Nil for non-SiriusXM streams.
        var type: String?

        /// Whether this is a non-music segment based on SiriusXM protocol metadata.
        /// Checks the TYPE field first, then falls back to `#`/`@` prefix heuristics
        /// for social media prompts during DJ segments (e.g., `#LSUG`, `@DelranPalmyra`).
        /// Additional pattern-based detection is handled by configurable filter rules
        /// (Settings → Scrobbling) applied in SonosEventHandler.
        var isDJOrNonMusic: Bool {
            // SiriusXM TYPE field: anything other than "SNG" is non-music
            if let type, type != "SNG" { return true }
            // Social media prompts during DJ segments use # and @ prefixes
            if let title, title.hasPrefix("#") || title.hasPrefix("@") { return true }
            if let artist, artist.hasPrefix("#") || artist.hasPrefix("@") { return true }
            return false
        }
    }

    /// Extract artist/title from `streamContent` if present.
    var parsedStreamContent: StreamContentInfo? {
        guard let content = streamContent, !content.isEmpty else { return nil }
        return Self.parseStreamContent(content)
    }

    static func parseStreamContent(_ content: String) -> StreamContentInfo {
        var info = StreamContentInfo()

        if content.contains("|") {
            // Pipe-delimited format (SiriusXM)
            for part in content.split(separator: "|") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ARTIST ") {
                    info.artist = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("TITLE ") {
                    info.title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("ALBUM ") {
                    let album = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if album != "undefined" {
                        info.album = album
                    }
                } else if trimmed.hasPrefix("TYPE=") {
                    info.type = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
            }
        } else if content.contains(" - ") {
            // Simple "Artist - Title" format (other radio)
            let parts = content.split(separator: " - ", maxSplits: 1)
            if parts.count == 2 {
                info.artist = String(parts[0]).trimmingCharacters(in: .whitespaces)
                info.title = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        return info
    }
}

// MARK: - Sonos Internal String Filter

extension DIDLLiteMetadata {
    /// Check if a metadata string is a Sonos internal identifier or stream artifact (not user-facing).
    ///
    /// Matches: `x-*`, `zp*`, `rincon_*`, anything with `://` in it,
    /// or stream filenames like `*.m3u8`, `*.mp3`, `*.aac`, `*.flac`, `*.mp4`.
    static func isSonosInternal(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.hasPrefix("x-") ||
               v.hasPrefix("zp") ||
               v.hasPrefix("rincon_") ||
               v.contains("://") ||
               v.hasSuffix(".m3u8") ||
               v.hasSuffix(".mp3") ||
               v.hasSuffix(".aac") ||
               v.hasSuffix(".flac") ||
               v.hasSuffix(".mp4") ||
               v.hasSuffix(".ogg") ||
               v.hasSuffix(".wma") ||
               // SomaFM-style stream names: "secretagent-128-mp3", "groovesalad-256-aac"
               v.hasSuffix("-mp3") ||
               v.hasSuffix("-aac") ||
               v.hasSuffix("-ogg")
    }

    /// Returns metadata with Sonos internal strings filtered out.
    var filtered: DIDLLiteMetadata {
        var copy = self
        if let t = copy.title, Self.isSonosInternal(t) {
            copy.title = nil
        }
        if let c = copy.creator, Self.isSonosInternal(c) {
            copy.creator = nil
        }
        return copy
    }
}

// MARK: - Album Art URI Resolution

extension DIDLLiteMetadata {
    /// Resolve the album art URI, making relative paths absolute using the speaker IP.
    ///
    /// Sonos sometimes returns relative URIs like `/getaa?s=1&u=...` which need
    /// to be prefixed with `http://{speakerIP}:1400`.
    ///
    /// HTTP URLs are kept as-is (NSAllowsArbitraryLoads covers them).
    /// Upgrading to HTTPS breaks some CDNs (e.g., SiriusXM via Akamai).
    func resolvedAlbumArtURL(speakerIP: String) -> URL? {
        guard let uri = albumArtURI, !uri.isEmpty else { return nil }

        // Already absolute — return as-is
        if uri.hasPrefix("https://") || uri.hasPrefix("http://") {
            return URL(string: uri)
        }

        // Relative — prefix with speaker base URL
        let base = "http://\(speakerIP):1400"
        let path = uri.hasPrefix("/") ? uri : "/\(uri)"
        return URL(string: "\(base)\(path)")
    }
}
