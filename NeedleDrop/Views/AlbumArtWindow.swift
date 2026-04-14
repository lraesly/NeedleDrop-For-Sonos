import AppKit
import SwiftUI

/// A floating panel that displays album art at its native resolution.
///
/// Opens centered on screen, sized to the image's natural dimensions
/// (capped at 80% of screen size). Closes on click, Escape, or losing focus.
@MainActor
final class AlbumArtWindow {
    private var panel: NSPanel?
    private var focusObserver: NSObjectProtocol?

    /// Show album art from a URL. Uses the image cache if available,
    /// otherwise downloads it first.
    func show(url: URL) {
        // Close any existing panel
        dismiss()

        // Try the cache first for instant display
        if let cached = ImageCache.shared.get(url) {
            showImage(cached, title: url.lastPathComponent)
        } else {
            // Download in background, then show (with ATS HTTPS fallback)
            Task {
                guard let image = await ImageCache.shared.download(url: url) else { return }
                showImage(image, title: url.lastPathComponent)
            }
        }
    }

    func dismiss() {
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
            focusObserver = nil
        }
        panel?.close()
        panel = nil
    }

    // MARK: - Private

    private func showImage(_ image: NSImage, title: String) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Use the image's pixel dimensions for native resolution
        let rep = image.representations.first
        let nativeWidth = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
        let nativeHeight = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))

        // Cap at 80% of screen, maintaining aspect ratio
        let maxWidth = screenFrame.width * 0.8
        let maxHeight = screenFrame.height * 0.8
        let scale = min(1.0, min(maxWidth / nativeWidth, maxHeight / nativeHeight))

        // Floor at 300pt so tiny art isn't awkwardly small
        let width = max(300, nativeWidth * scale)
        let height = max(300, nativeHeight * scale)

        let p = ClickDismissPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.title = "Album Art"
        p.isOpaque = false
        p.backgroundColor = .black
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Set min size so the window can't be shrunk to nothing
        p.minSize = NSSize(width: 200, height: 200)

        // Hide miniaturize and zoom buttons
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        // Host the image view
        let hostingView = NSHostingView(
            rootView: AlbumArtContentView(image: image)
        )
        p.contentView = hostingView

        // Center on screen
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2
        p.setFrameOrigin(NSPoint(x: x, y: y))

        // Close when losing focus
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }

        panel = p
        p.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Click-to-Dismiss Panel

/// NSPanel that closes when the user clicks inside it (on the image).
private final class ClickDismissPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Escape to close
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Album Art Content View

/// Full-bleed image view with a black background. Click to dismiss.
private struct AlbumArtContentView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .background(Color.black)
            .onTapGesture {
                NSApp.keyWindow?.close()
            }
            .contextMenu {
                Button("Copy Image") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                }
            }
    }
}
