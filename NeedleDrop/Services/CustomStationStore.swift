import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "CustomStationStore")

/// Persists user-defined stream stations to UserDefaults.
@MainActor
final class CustomStationStore: ObservableObject {
    @Published private(set) var stations: [CustomStation] = []

    private let storeKey = "customStations_v1"

    init() {
        stations = loadStations()
    }

    // MARK: - Mutations

    func add(_ station: CustomStation) {
        stations.append(station)
        save()
    }

    func update(_ station: CustomStation) {
        if let idx = stations.firstIndex(where: { $0.id == station.id }) {
            stations[idx] = station
            save()
        }
    }

    func remove(_ station: CustomStation) {
        stations.removeAll { $0.id == station.id }
        save()
    }

    // MARK: - Private

    private func loadStations() -> [CustomStation] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([CustomStation].self, from: data)
        } catch {
            log.error("Failed to decode custom stations: \(error.localizedDescription)")
            return []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(stations)
            UserDefaults.standard.set(data, forKey: storeKey)
        } catch {
            log.error("Failed to encode custom stations: \(error.localizedDescription)")
        }
    }
}
