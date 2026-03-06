import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "HomeStore")

/// A named Sonos home identified by its household ID.
struct Home: Codable, Identifiable, Equatable {
    var id: String { householdId }
    let householdId: String
    var name: String
}

/// Persists the mapping of Sonos household IDs to user-given home names.
@MainActor
final class HomeStore: ObservableObject {
    @Published private(set) var homes: [Home] = []

    private let storeKey = "savedHomes_v1"

    init() {
        homes = loadHomes()
    }

    // MARK: - Lookups

    /// Returns the user-given name for a household, or nil if unknown.
    func nameForHousehold(_ householdId: String) -> String? {
        homes.first(where: { $0.householdId == householdId })?.name
    }

    /// Returns true if this household has been seen before.
    func isKnownHousehold(_ householdId: String) -> Bool {
        homes.contains(where: { $0.householdId == householdId })
    }

    // MARK: - Mutations

    func addHome(householdId: String, name: String) {
        guard !isKnownHousehold(householdId) else { return }
        homes.append(Home(householdId: householdId, name: name))
        save()
        log.info("Added home '\(name)' for household \(householdId)")
    }

    func updateName(householdId: String, name: String) {
        if let idx = homes.firstIndex(where: { $0.householdId == householdId }) {
            homes[idx].name = name
            save()
        }
    }

    // MARK: - Private

    private func loadHomes() -> [Home] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([Home].self, from: data)
        } catch {
            log.error("Failed to decode homes: \(error.localizedDescription)")
            return []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(homes)
            UserDefaults.standard.set(data, forKey: storeKey)
        } catch {
            log.error("Failed to encode homes: \(error.localizedDescription)")
        }
    }
}
