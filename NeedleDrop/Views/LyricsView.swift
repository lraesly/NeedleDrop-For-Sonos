import SwiftUI

/// Renders synced lyrics with the current line highlighted and auto-scrolled
/// into view. Falls back to a static scrollable transcript when LRCLIB only
/// has plain lyrics, and to an empty state when there are no lyrics at all.
///
/// Position is consumed in seconds — the same `appState.playbackPosition`
/// that drives the progress bar. The current line is the latest line whose
/// timestamp is ≤ position, so the highlight ticks forward exactly as the
/// track plays.
struct LyricsView: View {
    let lyrics: ParsedLyrics?
    let position: Int

    var textColor: Color = .primary
    var highlightColor: Color = .accentColor
    var dimColor: Color = .secondary
    var background: Color = .clear

    var body: some View {
        Group {
            if let lyrics, lyrics.isSynced {
                syncedView(lyrics)
            } else if let plain = lyrics?.plain, !plain.isEmpty {
                plainView(plain)
            } else {
                emptyView
            }
        }
        .background(background)
    }

    // MARK: - Synced

    @ViewBuilder
    private func syncedView(_ lyrics: ParsedLyrics) -> some View {
        let active = currentIndex(lyrics)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lyrics.synced.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "\u{266A}" : line.text)
                            .font(.system(size: 14, weight: i == active ? .semibold : .regular))
                            .foregroundStyle(color(for: i, active: active))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .onChange(of: active) { newValue in
                guard let idx = newValue else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private func color(for index: Int, active: Int?) -> Color {
        guard let active else { return dimColor }
        if index == active { return highlightColor }
        let distance = abs(active - index)
        if distance <= 2 { return textColor }
        return dimColor.opacity(0.5)
    }

    private func currentIndex(_ lyrics: ParsedLyrics) -> Int? {
        let pos = Double(position)
        var idx: Int? = nil
        for (i, line) in lyrics.synced.enumerated() {
            if line.time <= pos { idx = i } else { break }
        }
        return idx
    }

    // MARK: - Plain / Empty

    @ViewBuilder
    private func plainView(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundStyle(dimColor)
            Text("No lyrics available")
                .font(.caption)
                .foregroundStyle(dimColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
