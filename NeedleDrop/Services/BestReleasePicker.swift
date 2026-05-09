import Foundation
import MusicKit

/// Picks the best release among MusicKit catalog candidates that all
/// nominally match a query, biasing toward the original studio album over
/// compilations, soundtracks, "best of" sets, and deluxe/remastered reissues.
///
/// Apple's catalog frequently lists the same recording on multiple releases
/// and `MusicCatalogSearchRequest` returns them in an order that does not
/// favor the original. Naive `results.first` selection pollutes the user's
/// library with compilation cover art and reissue release dates.
///
/// Heuristic ported from song_enrichment's `_apply_preferences` /
/// `_COMPILATION_ALBUM_RE` (~/Developer/song_enrichment/python/song_enrichment/matcher.py).
enum BestReleasePicker {
    /// Among `candidates`, prefer non-compilations, then earliest release
    /// date (typically the original studio album over reissues). Returns
    /// nil when `candidates` is empty.
    static func pickBest(among candidates: [Song]) -> Song? {
        candidates.min { lhs, rhs in
            let lc = isLikelyCompilation(lhs.albumTitle ?? "")
            let rc = isLikelyCompilation(rhs.albumTitle ?? "")
            if lc != rc { return !lc }
            let ld = lhs.releaseDate ?? .distantFuture
            let rd = rhs.releaseDate ?? .distantFuture
            return ld < rd
        }
    }

    /// True when an album title smells like a compilation, soundtrack,
    /// greatest-hits set, or special edition.
    static func isLikelyCompilation(_ albumTitle: String) -> Bool {
        guard !albumTitle.isEmpty else { return false }
        return albumTitle.range(
            of: compilationPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static let compilationPattern =
        #"\b(?:greatest\s+hits?|best\s+of|essentials?|a-?list|anthology|collection|compilation|box\s+set|complete|definitive|ultimate|hits?|gold|platinum|now\s+that[’']?s|soundtrack|original\s+(?:motion\s+)?picture|ost|music\s+from\s+(?:the\s+)?(?:motion\s+)?(?:picture|film|movie)|expanded\s+edition|deluxe\s+edition|remastered\s+edition)\b"#
}
