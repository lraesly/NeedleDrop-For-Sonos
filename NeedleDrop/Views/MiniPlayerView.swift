import SwiftUI

/// Compact now-playing view for the floating mini player window.
///
/// Two appearance modes controlled by `appState.isMiniPlayerTransparent`:
///
/// **Transparent** (default) — three visual states driven by hover:
/// - *Inactive*: content at ~12% opacity, no backdrop (title bar only).
/// - *Active* (hover / foreground): 60% black backdrop, white content.
/// - *Song change*: same as active, holds 4s then fades back.
///
/// **Solid** — always-visible content on a material background; no
/// hover-driven opacity changes.
struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - State

    @State private var isShowingSongChange = false
    @State private var songChangeTask: Task<Void, Never>?

    /// True when the content area should be fully visible (transparent mode).
    private var isActive: Bool { appState.isMiniPlayerActive || isShowingSongChange }

    /// Whether the transparent overlay style is active.
    private var transparent: Bool { appState.isMiniPlayerTransparent }

    // MARK: - Appearance Helpers

    private var shadow: Color { transparent ? .black.opacity(0.45) : .clear }

    private var titleColor: Color { transparent ? .white : Color(.labelColor) }
    private var subtitleColor: Color { transparent ? .white.opacity(0.7) : Color(.secondaryLabelColor) }
    private var tertiaryColor: Color { transparent ? .white.opacity(0.5) : Color(.tertiaryLabelColor) }
    private var iconColor: Color { transparent ? .white.opacity(0.6) : Color(.secondaryLabelColor) }
    private var transportColor: Color { transparent ? .white.opacity(0.8) : Color(.secondaryLabelColor) }
    private var dimColor: Color { transparent ? .white.opacity(0.3) : Color(.tertiaryLabelColor) }
    private var placeholderFill: Color { transparent ? .white.opacity(0.08) : Color(.quaternaryLabelColor) }

    // MARK: - Body

    var body: some View {
        ZStack {
            if transparent {
                Color.black.opacity(isActive ? 0.6 : 0)
            } else {
                Color(.windowBackgroundColor)
            }

            VStack(spacing: 8) {
                if let track = appState.nowPlaying.track, track.isTVAudio {
                    tvAudioContent(track: track)
                } else if let track = appState.nowPlaying.track {
                    musicContent(
                        track: track,
                        state: appState.nowPlaying.transportState
                    )
                } else {
                    emptyContent
                }
            }
            .padding(12)
            .opacity(transparent ? (isActive ? 1.0 : 0.12) : 1.0)
        }
        .frame(width: 300, height: 120)
        .onChange(of: appState.miniPlayerFlashCount) { _ in
            guard transparent else { return }
            songChangeTask?.cancel()
            withAnimation(.easeIn(duration: 0.2)) { isShowingSongChange = true }
            songChangeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1.0)) { isShowingSongChange = false }
            }
        }
    }

    // MARK: - Content Sections

    @ViewBuilder
    private func tvAudioContent(track: TrackInfo) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(placeholderFill)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "tv")
                        .font(.body)
                        .foregroundStyle(iconColor)
                        .shadow(color: shadow, radius: 2)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("TV Audio")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .shadow(color: shadow, radius: 2)

                if let zone = appState.nowPlaying.zoneName {
                    Text(zone)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor)
                        .shadow(color: shadow, radius: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        HStack {
            Spacer()
            volumeControl()
        }
    }

    @ViewBuilder
    private func musicContent(track: TrackInfo, state: TransportState) -> some View {
        // Top row: art + track info
        HStack(spacing: 10) {
            albumArt(track: track)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .shadow(color: shadow, radius: 2)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleColor)
                    .shadow(color: shadow, radius: 2)
                    .lineLimit(1)

                if let album = track.album, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 10))
                        .foregroundStyle(tertiaryColor)
                        .shadow(color: shadow, radius: 2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Bottom row: transport + heart + volume
        HStack(spacing: 12) {
            Button(action: { appState.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button(action: { appState.togglePlayPause() }) {
                Image(systemName: state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)

            Button(action: { appState.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            if appState.canSaveToLibrary {
                let isSaved = appState.lastSaveResult?.trackId == track.id
                    && appState.lastSaveResult?.anySucceeded == true

                Button(action: { appState.saveToLibrary() }) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .font(.system(size: 12))
                        .foregroundStyle(isSaved ? .red : iconColor)
                }
                .buttonStyle(.plain)
                .disabled(isSaved)
            }

            Spacer()
            volumeControl()
        }
        .foregroundStyle(transportColor)
        .shadow(color: shadow, radius: 2)
    }

    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundStyle(dimColor)
                .shadow(color: shadow, radius: 2)
            Text("Nothing playing")
                .font(.caption)
                .foregroundStyle(tertiaryColor)
                .shadow(color: shadow, radius: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Album Art

    @ViewBuilder
    private func albumArt(track: TrackInfo) -> some View {
        if let url = track.albumArtURL {
            CachedAsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                artPlaceholder
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.4), radius: 4)
        } else {
            artPlaceholder
        }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(placeholderFill)
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(dimColor)
            }
    }

    // MARK: - Volume Control

    private func volumeControl() -> some View {
        HStack(spacing: 4) {
            Button(action: { appState.toggleMute() }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconColor)
                    .shadow(color: shadow, radius: 2)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(appState.volume == 0 ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(appState.volume) },
                    set: { newValue in
                        appState.setVolume(Int(newValue))
                    }
                ),
                in: 0...100,
                step: 1
            )
            .frame(width: 70)
            .controlSize(.mini)
        }
    }

    // MARK: - Helpers

    private var volumeIcon: String {
        if appState.volume == 0 {
            return "speaker.slash.fill"
        } else if appState.volume < 33 {
            return "speaker.wave.1.fill"
        } else if appState.volume < 66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
