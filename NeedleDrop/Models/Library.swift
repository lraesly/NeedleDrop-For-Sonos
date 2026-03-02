import Foundation

/// Result of a save-to-library attempt for a single service.
struct ServiceSaveResult: Equatable {
    let service: String       // "spotify", "apple_music"
    let success: Bool
    let message: String?
    let trackName: String?    // what the service found/saved
    let trackUrl: String?     // URL to the saved track (for opening in app)
}

/// Aggregated detail for a track's library save attempts.
struct LibrarySaveDetail: Equatable {
    let trackId: String
    var results: [ServiceSaveResult]

    var anySucceeded: Bool { results.contains { $0.success } }
    var allFailed: Bool { !results.isEmpty && results.allSatisfy { !$0.success } }
}
