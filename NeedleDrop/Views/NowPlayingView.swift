import SwiftUI

/// Displays the currently playing track with album art, title, artist,
/// transport controls, and volume slider.
struct NowPlayingView: View {
    @EnvironmentObject var appState: AppState

    private var nowPlaying: NowPlayingState {
        appState.nowPlaying
    }

    var body: some View {
        if let track = nowPlaying.track {
            VStack(spacing: 0) {
                trackView(track)
                if !track.isTVAudio {
                    PlaybackProgressBar(
                        position: appState.playbackPosition,
                        duration: appState.playbackDuration,
                        showTimestamps: false
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
                transportControls
                volumeSlider
            }
        } else {
            emptyView
        }
    }

    // MARK: - Track View

    @ViewBuilder
    private func trackView(_ track: TrackInfo) -> some View {
        HStack(spacing: 10) {
            // Album art / TV icon
            if track.isTVAudio {
                Image("TVIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .frame(width: 64, height: 64)
            } else {
                CachedAsyncImage(url: track.albumArtURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color(.controlBackgroundColor)
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    if let url = track.albumArtURL {
                        appState.albumArtWindow.show(url: url)
                    }
                }
                .help("Click to enlarge")
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    Text(track.title)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(2)

                    if !track.isTVAudio, !track.isDJSegment {
                        Spacer(minLength: 2)
                        heartButton
                            .padding(.top, 1)
                    }
                }

                Text(track.isTVAudio ? (nowPlaying.zoneName ?? "") : track.artist)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if track.isTVAudio {
                    if let zone = appState.activeZone, !zone.members.isEmpty {
                        Text("\(zone.members.count + 1) speakers")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 4) {
                        if let album = track.album {
                            Text(album)
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }

                        if appState.scrobbleTracker.isScrobbled(track.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                                .fixedSize()
                                .help("Scrobbled")
                        }
                    }

                    if let station = nowPlaying.mediaTitle {
                        Text(station)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        let isTV = nowPlaying.track?.isTVAudio == true

        return HStack(spacing: 20) {
            if !isTV {
                Button {
                    appState.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Previous")
            }

            Button {
                appState.togglePlayPause()
            } label: {
                let isPlaying = isTV
                    ? !appState.isTVMuted
                    : nowPlaying.transportState == .playing
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(isTV
                  ? (appState.isTVMuted ? "Unmute" : "Mute")
                  : (nowPlaying.transportState == .playing ? "Pause" : "Play"))

            if !isTV {
                Button {
                    appState.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Next")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Heart Button

    @ViewBuilder
    private var heartButton: some View {
        let trackId = nowPlaying.track?.id
        let isSaved = trackId.map { appState.savedTrackIds.contains($0) } ?? false
        let isSaving = trackId != nil && appState.savingTrackId == trackId
        let canSave = appState.canSaveToLibrary

        if isSaved {
            // Show a plain image — no disabled-button dimming
            Image(systemName: "heart.fill")
                .font(.body)
                .foregroundColor(.red)
                .help("In your library")
        } else {
            Button {
                appState.saveToLibrary()
            } label: {
                Image(systemName: isSaving ? "heart.fill" : "heart")
                    .font(.body)
                    .foregroundColor(
                        isSaving ? .red.opacity(0.4) :
                        canSave ? .secondary : .secondary.opacity(0.3)
                    )
            }
            .buttonStyle(.plain)
            .help(canSave ? "Save to library" : "Connect Spotify or Apple Music in Setup to save tracks")
            .disabled(isSaving || !canSave)
        }
    }

    // MARK: - Volume Slider

    private var volumeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundColor(.secondary)

            dropdownVolumeSlider

            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear {
            appState.refreshVolume()
        }
    }

    // MARK: - Custom Volume Slider

    /// Custom single-track volume slider matching the mini player style.
    private var dropdownVolumeSlider: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let ratio = CGFloat(appState.volume) / 100.0
            let trackHeight: CGFloat = 4
            let thumbSize: CGFloat = 12

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor)
                    .frame(width: ratio * width, height: trackHeight)

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
        .frame(height: 12)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 4) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Nothing playing")
                .font(.caption)
                .foregroundColor(.secondary)
            if let zone = nowPlaying.zoneName {
                Text(zone)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }
}
