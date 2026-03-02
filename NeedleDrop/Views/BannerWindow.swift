import AppKit
import SwiftUI

/// A floating, non-activating window for track-change notifications.
/// Appears briefly at the top-right of the screen with album art and track info.
@MainActor
final class BannerWindow {
    private var window: NSWindow?
    private let bannerWidth: CGFloat = 320
    private let bannerHeight: CGFloat = 80

    func showBanner(track: TrackInfo, appState: AppState) {
        // Create window fresh each time for reliability
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = false
        w.hidesOnDeactivate = false
        w.canHide = false
        w.ignoresMouseEvents = true

        // Set SwiftUI content — inject appState so art updates reactively
        let bannerView = BannerView(track: track).environmentObject(appState)
        let hostingView = NSHostingView(rootView: bannerView)
        hostingView.frame = NSRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight)
        w.contentView = hostingView

        // Position at top-right of the main screen, below the menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - bannerWidth - 16
            let y = screenFrame.maxY - bannerHeight - 8
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Dismiss previous window if any
        self.window?.orderOut(nil)
        self.window = w

        // Show with fade in
        w.alphaValue = 0
        w.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
    }

    func dismissBanner() {
        guard let w = window, w.isVisible else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        })
    }
}
