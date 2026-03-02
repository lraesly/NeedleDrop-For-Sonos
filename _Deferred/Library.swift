import Foundation

/// Result of a save-to-library attempt for a single service.
struct ServiceSaveResult: Equatable {
    let service: String       // "spotify", "apple_music"
    let success: Bool
    let errorMessage: String?
    let trackName: String?    // what the service found/saved (may differ from input)
}

/// Aggregated detail for a track's library save attempts.
struct LibrarySaveDetail: Equatable {
    let trackId: String
    var results: [ServiceSaveResult]

    var anySucceeded: Bool { results.contains { $0.success } }
    var allFailed: Bool { !results.isEmpty && results.allSatisfy { !$0.success } }
}
