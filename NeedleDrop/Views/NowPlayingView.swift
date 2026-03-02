import SwiftUI

/// Displays the currently playing track with album art, title, and artist.
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
                trackView(track)
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

                if let album = track.album {
                    Text(album)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Transport state indicator
            transportIndicator
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transport Indicator

    @ViewBuilder
    private var transportIndicator: some View {
        switch nowPlaying.transportState {
        case .playing:
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        case .stopped:
            Image(systemName: "stop.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        case .transitioning:
            ProgressView()
                .controlSize(.small)
        case .unknown:
            EmptyView()
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
