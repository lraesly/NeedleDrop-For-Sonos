import AppKit
import SwiftUI

/// A floating panel that shows alternative album-art candidates from iTunes
/// Search. Click a tile to apply it as a preferred override for the current
/// (artist, title). Closes on Escape, click outside, or pick.
@MainActor
final class AltArtPickerWindow {
    private var panel: NSPanel?
    private var focusObserver: NSObjectProtocol?

    func show(appState: AppState) {
        dismiss()

        guard let track = appState.nowPlaying.track else { return }
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let width: CGFloat = 540
        let height: CGFloat = 460

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.title = "Alternative Art — \(track.artist) — \(track.title)"
        p.isOpaque = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 360, height: 320)
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        let host = NSHostingView(
            rootView: AltArtPickerView(appState: appState) { [weak self] in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        )
        p.contentView = host

        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2
        p.setFrameOrigin(NSPoint(x: x, y: y))

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

    func dismiss() {
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
            focusObserver = nil
        }
        panel?.close()
        panel = nil
    }
}

// MARK: - Picker View

private struct AltArtPickerView: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void

    @State private var candidates: [AltArtCandidate] = []
    @State private var isLoading = true

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                if isLoading {
                    ProgressView()
                        .padding(.top, 60)
                } else if candidates.isEmpty {
                    Text("No alternatives found.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(candidates) { candidate in
                            candidateTile(candidate)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            if let track = appState.nowPlaying.track {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(.body, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Refresh") { Task { await load() } }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func candidateTile(_ candidate: AltArtCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CachedAsyncImage(url: candidate.artURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Color(.controlBackgroundColor)
                    ProgressView().scaleEffect(0.5)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )

            Text(candidate.trackName)
                .font(.caption)
                .lineLimit(1)
            if let album = candidate.albumName {
                Text(album)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 140, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.useAlternativeArt(candidate.artURL)
            onClose()
        }
        .help("Click to use this art")
    }

    private func load() async {
        isLoading = true
        candidates = await appState.fetchAlbumArtCandidates()
        isLoading = false
    }
}
