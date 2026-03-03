import SwiftUI

/// A drop-in replacement for AsyncImage that caches downloaded images in memory.
/// Avoids re-fetching album art every time the view appears.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                content(Image(nsImage: image))
            } else if failed || url == nil {
                placeholder()
            } else {
                placeholder()
            }
        }
        // .task(id:) fires on initial appearance AND whenever `url` changes,
        // cancelling any in-flight download for the old URL.
        .task(id: url) {
            failed = false
            // If the new URL is already cached, swap instantly (no placeholder flash).
            // Otherwise nil out the old image to show the placeholder while downloading.
            if let url, let cached = ImageCache.shared.get(url) {
                self.image = cached
                return
            }
            self.image = nil
            await load()
        }
    }

    private func load() async {
        guard let url else { return }

        // Check cache first (may have been populated between task start and here)
        if let cached = ImageCache.shared.get(url) {
            self.image = cached
            return
        }

        // Download with HTTPS fallback for ATS-blocked HTTP URLs.
        // macOS 26+ no longer honors NSAllowsArbitraryLoads for HTTP,
        // so external HTTP art URLs (e.g. SiriusXM CDN) need upgrading.
        if let nsImage = await ImageCache.shared.download(url: url) {
            self.image = nsImage
        } else {
            failed = true
        }
    }
}

/// Simple in-memory image cache keyed by URL.
///
/// Uses `NSCache` for automatic eviction under memory pressure.
/// Each 600×600 image is ~1.4 MB, so 50 entries ≈ 70 MB worst case.
/// `NSCache` will purge entries before hitting that limit if the system
/// needs memory.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 50
        // 30 MB total cost limit — each entry's cost = byte count of image data
        c.totalCostLimit = 30 * 1024 * 1024
        return c
    }()

    func get(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Remove all cached images (e.g. on system sleep to reclaim memory).
    func clearAll() {
        cache.removeAllObjects()
    }

    func set(_ image: NSImage, for url: URL) {
        // Estimate memory cost from pixel dimensions (width × height × 4 bytes/pixel)
        let rep = image.representations.first
        let w = rep?.pixelsWide ?? Int(image.size.width)
        let h = rep?.pixelsHigh ?? Int(image.size.height)
        let cost = w * h * 4
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    /// Download an image, caching it, upgrading external HTTP to HTTPS.
    ///
    /// macOS 26+ no longer honors `NSAllowsArbitraryLoads` for HTTP loads.
    /// External HTTP art URLs (e.g. SiriusXM CDN) get ATS error -1022.
    /// This method upgrades external HTTP URLs to HTTPS proactively to avoid
    /// ATS error logging, while keeping local-network HTTP URLs as-is.
    func download(url: URL) async -> NSImage? {
        // Check cache first
        if let cached = get(url) { return cached }

        // For external HTTP URLs, try HTTPS first to avoid ATS errors.
        // Local network URLs (Sonos speakers) stay as HTTP.
        // Domains with known TLS cert mismatches keep HTTP (covered by
        // per-domain ATS exception in Info.plist).
        let loadURL: URL
        if url.scheme == "http", !isLocalNetwork(url: url), !hasATSException(url: url),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            loadURL = components.url ?? url
        } else {
            loadURL = url
        }

        if let image = await fetchImage(url: loadURL) {
            set(image, for: url) // Cache under original URL
            return image
        }

        // If HTTPS upgrade failed, try original HTTP as last resort
        if loadURL != url, let image = await fetchImage(url: url) {
            set(image, for: url)
            return image
        }

        return nil
    }

    /// Whether a URL points to the local network (Sonos speakers, etc.)
    private func isLocalNetwork(url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.hasPrefix("172.")
            || host.hasSuffix(".local")
            || host == "localhost"
            || host == "127.0.0.1"
    }

    /// Domains with per-domain ATS exceptions in Info.plist that allow HTTP.
    /// These have known TLS issues (e.g. CDN cert mismatch) — skip HTTPS
    /// upgrade to avoid noisy error logging.
    private func hasATSException(url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host == "pri.art.prod.streaming.siriusxm.com"
            || host == "albumart.siriusxm.com"
    }

    /// Dedicated session for image downloads — URL caching disabled to prevent
    /// unbounded memory growth from album art responses.
    private static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func fetchImage(url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await Self.imageSession.data(for: request) else { return nil }
        return NSImage(data: data)
    }
}
