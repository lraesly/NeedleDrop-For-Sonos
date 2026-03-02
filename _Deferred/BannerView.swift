import SwiftUI

/// Compact banner content: album art + track title + artist.
/// Observes AppState so the art updates reactively when the server enriches it
/// after the initial track-change event (common with radio streams).
struct BannerView: View {
    @EnvironmentObject var appState: AppState

    /// Snapshot used only for text — keeps title/artist stable even if a
    /// second track-change fires while the banner is still visible.
    let track: TrackInfo

    /// Live album art URL: prefer the latest value from appState (may arrive
    /// after the initial event), fall back to the snapshot, then to the
    /// source favorite's artwork.
    private var artURL: URL? {
        if let url = appState.nowPlaying?.track?.albumArtUrl, let parsed = URL(string: url) {
            return parsed
        }
        if let url = track.albumArtUrl, let parsed = URL(string: url) {
            return parsed
        }
        // Fall back to the matching favorite's artwork (station logo)
        if let sourceUri = appState.nowPlaying?.track?.sourceUri ?? track.sourceUri,
           let fav = appState.favorites.first(where: { $0.uri == sourceUri }),
           let artUri = fav.albumArtUri, let parsed = URL(string: artUri) {
            return parsed
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // Album art
            if let url = artURL {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    artPlaceholder
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                artPlaceholder
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 0) {
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let album = track.album, !album.isEmpty {
                        Text(" \u{2014} ")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(album)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 320, height: 80)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 0.5)
        }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(width: 48, height: 48)
            .overlay {
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
    }
}
