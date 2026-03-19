import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "ScheduleClient")

/// REST client for the server-side playback scheduler.
/// Reuses the ScrobblerClient's base URL and auth token.
@MainActor
final class ScheduleClient {

    private weak var scrobblerClient: ScrobblerClient?

    init(scrobblerClient: ScrobblerClient) {
        self.scrobblerClient = scrobblerClient
    }

    // MARK: - CRUD

    func listSchedules() async throws -> [PlaybackSchedule] {
        let data = try await get("/api/schedules")
        let wrapper = try JSONDecoder().decode(ScheduleListResponse.self, from: data)
        return wrapper.schedules
    }

    func createSchedule(_ schedule: PlaybackSchedule) async throws -> PlaybackSchedule {
        let body = try JSONEncoder().encode(schedule)
        let data = try await request(method: "POST", path: "/api/schedules", body: body)
        return try JSONDecoder().decode(PlaybackSchedule.self, from: data)
    }

    func updateSchedule(_ schedule: PlaybackSchedule) async throws -> PlaybackSchedule {
        let body = try JSONEncoder().encode(schedule)
        let data = try await request(method: "PUT", path: "/api/schedules/\(schedule.id)", body: body)
        return try JSONDecoder().decode(PlaybackSchedule.self, from: data)
    }

    func deleteSchedule(id: String) async throws {
        _ = try await request(method: "DELETE", path: "/api/schedules/\(id)", body: nil)
    }

    func testSchedule(id: String) async throws {
        _ = try await request(method: "POST", path: "/api/schedules/\(id)/test", body: nil)
    }

    /// Fetch speaker names from the server (for room selection when local topology is unavailable).
    func getSpeakerNames() async throws -> [String] {
        let data = try await get("/api/speakers")
        let wrapper = try JSONDecoder().decode(SpeakerListResponse.self, from: data)
        return wrapper.speakers.map(\.name).sorted()
    }

    // MARK: - HTTP helpers

    private func get(_ path: String) async throws -> Data {
        try await request(method: "GET", path: path, body: nil)
    }

    private func request(method: String, path: String, body: Data?) async throws -> Data {
        guard let config = scrobblerClient?.config else {
            throw ScheduleError.notConnected
        }

        guard let url = URL(string: "\(config.baseURL.absoluteString)\(path)") else {
            throw ScheduleError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10

        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.error("\(method) \(path) failed: HTTP \(statusCode)")
            throw ScheduleError.httpError(statusCode)
        }

        return data
    }

    // MARK: - Types

    private struct ScheduleListResponse: Codable {
        let schedules: [PlaybackSchedule]
    }

    private struct SpeakerListResponse: Codable {
        let speakers: [SpeakerEntry]
    }

    private struct SpeakerEntry: Codable {
        let name: String
    }

    enum ScheduleError: Error, LocalizedError {
        case notConnected
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to NeedleDrop server"
            case .invalidResponse: return "Invalid server response"
            case .httpError(let code): return "Server error (HTTP \(code))"
            }
        }
    }
}
