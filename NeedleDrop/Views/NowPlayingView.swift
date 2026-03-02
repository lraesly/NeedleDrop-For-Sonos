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
            if track.isTVAudio {
                tvAudioView
            } else {
                VStack(spacing: 0) {
                    trackView(track)
                    transportControls
                    volumeSlider
                }
            }
        } else {
            emptyView
        }
    }

    // MARK: - Track View

    @ViewBuilder
    private func trackView(_ track: TrackInfo) -> some View {
        HStack(spacing: 10) {
            // Album art
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

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(2)

                Text(track.artist)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let album = track.album {
                        Text(album)
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }

                    if appState.scrobbleTracker.isScrobbled(track.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .help("Scrobbled")
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
        HStack(spacing: 20) {
            Button {
                appState.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("Previous")

            Button {
                appState.togglePlayPause()
            } label: {
                Image(systemName: nowPlaying.transportState == .playing
                      ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(nowPlaying.transportState == .playing ? "Pause" : "Play")

            Button {
                appState.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("Next")

            // Heart / save to library
            if appState.canSaveToLibrary {
                Spacer()
                heartButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Heart Button

    private var heartButton: some View {
        let isSaved = appState.lastSaveResult?.trackId == nowPlaying.track?.id
            && appState.lastSaveResult?.anySucceeded == true

        return Button {
            appState.saveToLibrary()
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.body)
                .foregroundColor(isSaved ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .help("Save to library")
        .disabled(isSaved)
    }

    // MARK: - Volume Slider

    private var volumeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundColor(.secondary)

            Slider(
                value: Binding(
                    get: { Double(appState.volume) },
                    set: { appState.setVolume(Int($0)) }
                ),
                in: 0...100,
                step: 1
            )
            .controlSize(.small)

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

    // MARK: - TV Audio

    private var tvAudioView: some View {
        HStack(spacing: 10) {
            ZStack {
                Color(.controlBackgroundColor)
                Image(systemName: "tv")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text("TV Audio")
                    .font(.system(.body, weight: .medium))

                if let zone = nowPlaying.zoneName {
                    Text(zone)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
