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
///
/// Two size modes controlled by `appState.miniPlayerSize`:
/// - **Compact** (300×120): horizontal layout with small art.
/// - **Large** (400×320): vertical layout with large centered art.
struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - State

    @State private var isShowingSongChange = false
    @State private var songChangeTask: Task<Void, Never>?

    /// True when the content area should be fully visible (transparent mode).
    private var isActive: Bool { appState.isMiniPlayerActive || isShowingSongChange }

    /// Whether the transparent overlay style is active.
    private var transparent: Bool { appState.isMiniPlayerTransparent }

    // MARK: - Size Helpers

    private var isLarge: Bool { appState.miniPlayerSize == .large }

    private var playerWidth: CGFloat { isLarge ? 400 : 300 }
    private var playerHeight: CGFloat { isLarge ? 385 : 135 }
    private var artSize: CGFloat { isLarge ? 200 : 56 }

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

            VStack(spacing: isLarge ? 12 : 8) {
                if let track = appState.nowPlaying.track {
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
        .frame(width: playerWidth, height: playerHeight)
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
    private func musicContent(track: TrackInfo, state: TransportState) -> some View {
        if isLarge {
            largeMusicContent(track: track, state: state)
        } else {
            compactMusicContent(track: track, state: state)
        }
    }

    // MARK: - Compact Layout (300×120)

    @ViewBuilder
    private func compactMusicContent(track: TrackInfo, state: TransportState) -> some View {
        let isTV = track.isTVAudio

        // Top row: art + track info
        HStack(spacing: 10) {
            albumArt(track: track)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .shadow(color: shadow, radius: 2)
                    .lineLimit(1)

                Text(isTV ? (appState.nowPlaying.zoneName ?? "") : track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleColor)
                    .shadow(color: shadow, radius: 2)
                    .lineLimit(1)

                if isTV {
                    if let zone = appState.activeZone, !zone.members.isEmpty {
                        Text("\(zone.members.count + 1) speakers")
                            .font(.system(size: 10))
                            .foregroundStyle(tertiaryColor)
                            .shadow(color: shadow, radius: 2)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 3) {
                        if let album = track.album, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 10))
                                .foregroundStyle(tertiaryColor)
                                .shadow(color: shadow, radius: 2)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
                            .shadow(color: shadow, radius: 2)
                            .fixedSize()
                            .help("Scrobbled")
                            .opacity(appState.scrobbleTracker.isScrobbled(track.id) && appState.scrobblerClient.config != nil ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Progress bar (compact: bar only, no timestamps)
        if !isTV {
            compactProgressBar
                .opacity(appState.playbackDuration > 0 ? 1 : 0)
        }

        // Bottom row: transport + heart + volume
        HStack(spacing: 12) {
            if !isTV {
                Button(action: { appState.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(HoverButtonStyle())
            }

            do {
                let isPlaying = isTV
                    ? !appState.isTVMuted
                    : state == .playing
                Button(action: { appState.togglePlayPause() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(HoverButtonStyle())
            }

            if !isTV {
                Button(action: { appState.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(HoverButtonStyle())

                if !track.isDJSegment {
                    do {
                        let isSaved = appState.savedTrackIds.contains(track.id)
                        let isSaving = appState.savingTrackId == track.id
                        let canSave = appState.canSaveToLibrary

                        if isSaved {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        } else {
                            Button(action: { appState.saveToLibrary() }) {
                                Image(systemName: isSaving ? "heart.fill" : "heart")
                                    .font(.system(size: 12))
                                    .foregroundStyle(
                                        isSaving ? .red.opacity(0.4) :
                                        canSave ? iconColor : iconColor.opacity(0.3)
                                    )
                            }
                            .buttonStyle(HoverButtonStyle())
                            .disabled(isSaving)
                        }
                    }
                }
            }

            Spacer()
            volumeControl()
        }
        .foregroundStyle(transportColor)
        .shadow(color: shadow, radius: 2)
    }

    // MARK: - Large Layout (400×320)

    @ViewBuilder
    private func largeMusicContent(track: TrackInfo, state: TransportState) -> some View {
        let isTV = track.isTVAudio

        // Large centered album art / TV icon
        albumArt(track: track)

        // Centered track info
        VStack(spacing: 2) {
            Text(track.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(titleColor)
                .shadow(color: shadow, radius: 2)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Text(isTV ? (appState.nowPlaying.zoneName ?? "") : track.artist)
                .font(.system(size: 13))
                .foregroundStyle(subtitleColor)
                .shadow(color: shadow, radius: 2)
                .lineLimit(1)

            if isTV {
                if let zone = appState.activeZone, !zone.members.isEmpty {
                    Text("\(zone.members.count + 1) speakers")
                        .font(.system(size: 11))
                        .foregroundStyle(tertiaryColor)
                        .shadow(color: shadow, radius: 2)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 4) {
                    if let album = track.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 11))
                            .foregroundStyle(tertiaryColor)
                            .shadow(color: shadow, radius: 2)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .shadow(color: shadow, radius: 2)
                        .fixedSize()
                        .help("Scrobbled")
                        .opacity(appState.scrobbleTracker.isScrobbled(track.id) && appState.scrobblerClient.config != nil ? 1 : 0)
                }
            }
        }

        // Progress bar (large: with timestamps)
        if !isTV {
            PlaybackProgressBar(
                position: appState.playbackPosition,
                duration: appState.playbackDuration,
                trackColor: transparent ? .white.opacity(0.15) : Color.secondary.opacity(0.2),
                fillColor: transparent ? .white.opacity(0.6) : Color.accentColor,
                timeColor: tertiaryColor
            )
            .shadow(color: shadow, radius: 2)
        }

        // Transport controls + heart
        HStack(spacing: 16) {
            if !isTV {
                Button(action: { appState.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(HoverButtonStyle())
            }

            do {
                let isPlaying = isTV
                    ? !appState.isTVMuted
                    : state == .playing
                Button(action: { appState.togglePlayPause() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(HoverButtonStyle())
            }

            if !isTV {
                Button(action: { appState.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(HoverButtonStyle())

                if !track.isDJSegment {
                    do {
                        let isSaved = appState.savedTrackIds.contains(track.id)
                        let isSaving = appState.savingTrackId == track.id
                        let canSave = appState.canSaveToLibrary

                        if isSaved {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                        } else {
                            Button(action: { appState.saveToLibrary() }) {
                                Image(systemName: isSaving ? "heart.fill" : "heart")
                                    .font(.system(size: 14))
                                    .foregroundStyle(
                                        isSaving ? .red.opacity(0.4) :
                                        canSave ? iconColor : iconColor.opacity(0.3)
                                    )
                            }
                            .buttonStyle(HoverButtonStyle())
                            .disabled(isSaving)
                        }
                    }
                }
            }
        }
        .foregroundStyle(transportColor)
        .shadow(color: shadow, radius: 2)

        // Full-width volume slider
        volumeControl()
    }

    private var emptyContent: some View {
        VStack(spacing: 6) {
            switch appState.connectionState {
            case .disconnected:
                Image(systemName: "wifi.slash")
                    .font(.system(size: isLarge ? 28 : 20))
                    .foregroundStyle(dimColor)
                    .shadow(color: shadow, radius: 2)
                Text("No speakers found")
                    .font(.caption)
                    .foregroundStyle(tertiaryColor)
                    .shadow(color: shadow, radius: 2)

            case .discovering:
                ProgressView()
                    .scaleEffect(isLarge ? 0.8 : 0.6)
                    .tint(dimColor)
                Text("Searching\u{2026}")
                    .font(.caption)
                    .foregroundStyle(tertiaryColor)
                    .shadow(color: shadow, radius: 2)

            case .connected:
                Image(systemName: "music.note")
                    .font(.system(size: isLarge ? 28 : 20))
                    .foregroundStyle(dimColor)
                    .shadow(color: shadow, radius: 2)
                Text("Nothing playing")
                    .font(.caption)
                    .foregroundStyle(tertiaryColor)
                    .shadow(color: shadow, radius: 2)

            case .error(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: isLarge ? 28 : 20))
                    .foregroundStyle(dimColor)
                    .shadow(color: shadow, radius: 2)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(tertiaryColor)
                    .shadow(color: shadow, radius: 2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Album Art

    @ViewBuilder
    private func albumArt(track: TrackInfo) -> some View {
        if track.isTVAudio {
            Image("TVIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: artSize * 0.85, height: artSize * 0.85)
                .frame(width: artSize, height: artSize)
                .opacity(transparent ? 0.85 : 1.0)
        } else if let url = track.albumArtURL {
            CachedAsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                artPlaceholder
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: isLarge ? 10 : 6))
            .shadow(color: .black.opacity(0.4), radius: isLarge ? 8 : 4)
            .onTapGesture {
                appState.albumArtWindow.show(url: url)
            }
            .help("Click to enlarge")
        } else {
            artPlaceholder
        }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: isLarge ? 10 : 6)
            .fill(placeholderFill)
            .frame(width: artSize, height: artSize)
            .overlay {
                Image(systemName: "music.note")
                    .font(isLarge ? .title : .body)
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
            .buttonStyle(HoverButtonStyle())
            .help(appState.isMuted || appState.volume == 0 ? "Unmute" : "Mute")

            customVolumeSlider
        }
    }

    /// Custom volume slider that renders as a single rounded track.
    private var customVolumeSlider: some View {
        let sliderWidth: CGFloat = isLarge ? 280 : 70
        let trackHeight: CGFloat = isLarge ? 4 : 3
        let thumbSize: CGFloat = isLarge ? 12 : 8

        return GeometryReader { geometry in
            let width = geometry.size.width
            let ratio = CGFloat(appState.volume) / 100.0

            ZStack(alignment: .leading) {
                // Single track background
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(transparent ? Color.white.opacity(0.15) : Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)

                // Fill
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(transparent ? Color.white.opacity(0.5) : Color.accentColor)
                    .frame(width: ratio * width, height: trackHeight)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: ratio * (width - thumbSize))
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newRatio = max(0, min(value.location.x / width, 1.0))
                        appState.setVolume(Int(newRatio * 100))
                    }
            )
        }
        .frame(width: sliderWidth, height: thumbSize)
    }

    // MARK: - Compact Progress Bar

    /// Minimal progress bar for compact layout — just the bar, no timestamps.
    private var compactProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(transparent ? Color.white.opacity(0.15) : Color.secondary.opacity(0.2))
                    .frame(height: 2)

                RoundedRectangle(cornerRadius: 1)
                    .fill(transparent ? Color.white.opacity(0.5) : Color.accentColor)
                    .frame(
                        width: appState.playbackDuration > 0
                            ? min(CGFloat(appState.playbackPosition) / CGFloat(appState.playbackDuration), 1.0) * geometry.size.width
                            : 0,
                        height: 2
                    )
            }
        }
        .frame(height: 2)
        .shadow(color: shadow, radius: 2)
    }

    // MARK: - Helpers

    private var volumeIcon: String {
        if appState.isMuted || appState.volume == 0 {
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
