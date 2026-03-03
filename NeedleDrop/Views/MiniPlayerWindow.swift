import AppKit
import SwiftUI

// MARK: - Hover Poller

/// Lightweight 10 Hz timer that checks whether the cursor is inside a window.
/// Plain NSObject (not @MainActor) to avoid Swift-concurrency isolation issues
/// with Timer's @Sendable closure requirement.
private final class HoverPoller: NSObject {
    weak var panel: NSPanel?
    var onStateChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var lastState = false

    func start() {
        timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        guard let panel else { return }
        let isInside = panel.frame.contains(NSEvent.mouseLocation)
        if isInside != lastState {
            lastState = isInside
            onStateChange?(isInside)
        }
    }
}

// MARK: - Keyable Panel

/// NSPanel subclass that accepts key status when clicked, even with
/// `.nonactivatingPanel`.  This lets the title-bar click trigger
/// `didBecomeKeyNotification` without stealing focus from other apps.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// NSHostingView subclass that prevents the window background drag from
/// intercepting SwiftUI gesture interactions (e.g. volume slider DragGesture).
/// The title bar remains draggable; only the content area is excluded.
private final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Mini Player Window

/// A floating, always-on-top mini player panel.
/// Draggable, non-activating (doesn't steal focus), with a close button.
/// Remembers position between toggle-off/toggle-on within the same app session.
///
/// Active state (`appState.isMiniPlayerActive`) is set when:
/// - The cursor is anywhere over the window (hover — via 10 Hz polling), or
/// - The panel becomes the key window (title-bar click).
@MainActor
final class MiniPlayerWindow {
    private var panel: NSPanel?
    private var lastOrigin: NSPoint?

    private var panelWidth: CGFloat {
        appStateRef?.miniPlayerSize == .large ? 400 : 300
    }
    private var panelHeight: CGFloat {
        appStateRef?.miniPlayerSize == .large ? 385 : 135
    }
    private var closeObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var hoverPoller: HoverPoller?
    private weak var appStateRef: AppState?

    func show(appState: AppState) {
        // If already showing, just bring to front
        if let existing = panel, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        appStateRef = appState

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.title = "NeedleDrop"
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Hide miniaturize and zoom buttons — only keep close
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        // Host the compact SwiftUI view.
        // NonDraggableHostingView prevents isMovableByWindowBackground from
        // intercepting SwiftUI DragGestures (volume slider, progress bar, etc.).
        let hostingView = NonDraggableHostingView(
            rootView: MiniPlayerView().environmentObject(appState)
        )
        p.contentView = hostingView

        // --- Hover tracking (cursor over window frame) ---
        let poller = HoverPoller()
        poller.panel = p
        poller.onStateChange = { [weak appState, weak p] isInside in
            Task { @MainActor in
                let panelIsKey = p?.isKeyWindow ?? false
                let shouldBeActive = isInside || panelIsKey
                guard appState?.isMiniPlayerActive != shouldBeActive else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState?.isMiniPlayerActive = shouldBeActive
                }
            }
        }
        hoverPoller = poller
        poller.start()

        // --- Key-window tracking (title-bar click) ---
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: p,
            queue: .main
        ) { [weak appState] _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                appState?.isMiniPlayerActive = true
            }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak appState, weak p] _ in
            let mouseInside = p.map { $0.frame.contains(NSEvent.mouseLocation) } ?? false
            if !mouseInside {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState?.isMiniPlayerActive = false
                }
            }
        }

        // Restore previous position or center on screen
        if let origin = lastOrigin {
            p.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.midY - panelHeight / 2
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Sync state when the user clicks the red close button
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: p,
            queue: .main
        ) { [weak self, weak appState] _ in
            self?.lastOrigin = self?.panel?.frame.origin
            self?.panel = nil
            self?.cleanup()
            appState?.isMiniPlayerVisible = false
            appState?.isMiniPlayerActive = false
        }

        panel = p
        p.orderFrontRegardless()
    }

    func dismiss() {
        guard let p = panel else { return }
        lastOrigin = p.frame.origin
        cleanup()
        p.close()
        panel = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Resize the panel to match a new mini player size setting.
    /// Keeps the top-left corner pinned and animates the transition.
    func resize(for size: MiniPlayerSize) {
        guard let panel else { return }
        let newWidth: CGFloat = size == .large ? 400 : 300
        let newHeight: CGFloat = size == .large ? 385 : 135

        // Keep top-left corner in place (macOS origin is bottom-left)
        let currentFrame = panel.frame
        let newOriginY = currentFrame.origin.y + currentFrame.height - newHeight
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newOriginY,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: true)
    }

    /// Update the title bar to reflect the current track or station.
    func updateTitle(for track: TrackInfo?, mediaTitle: String?) {
        guard let panel else { return }
        if let track, track.isTVAudio {
            panel.title = "TV Audio"
        } else if let mediaTitle {
            panel.title = mediaTitle
        } else if let track {
            panel.title = "\(track.artist) – \(track.title)"
        } else {
            panel.title = "NeedleDrop"
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        hoverPoller?.stop()
        hoverPoller = nil
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
        if let o = resignKeyObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = nil
        keyObserver = nil
        resignKeyObserver = nil
    }
}
