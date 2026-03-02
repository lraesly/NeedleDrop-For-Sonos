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

        // Download
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let nsImage = NSImage(data: data) {
                ImageCache.shared.set(nsImage, for: url)
                self.image = nsImage
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

/// Simple in-memory image cache keyed by URL.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let lock = NSLock()
    private var cache: [URL: NSImage] = [:]
    private var accessOrder: [URL] = []
    private let maxEntries = 100

    func get(_ url: URL) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url]
    }

    func set(_ image: NSImage, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache[url] = image
        // Track access order for eviction
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
        // Evict oldest if over limit
        while accessOrder.count > maxEntries {
            let oldest = accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
