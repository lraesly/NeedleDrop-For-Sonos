import Foundation

/// Persists presets to UserDefaults, scoped by server token.
@MainActor
final class PresetStore: ObservableObject {
    /// Presets for the currently connected server.
    @Published private(set) var presets: [Preset] = []

    private let storeKey = "savedPresets"
    private var currentServerToken: String?

    // MARK: - Server Scoping

    /// Load presets for a specific server. Call on connect.
    func loadForServer(token: String) {
        currentServerToken = token
        presets = presetsForToken(token)
    }

    /// Clear presets (call on disconnect).
    func clear() {
        currentServerToken = nil
        presets = []
    }

    // MARK: - Mutations

    func add(_ preset: Preset) {
        guard let token = currentServerToken else { return }
        var all = allEntries()
        all.append(PresetEntry(serverToken: token, preset: preset))
        saveEntries(all)
        presets = presetsForToken(token)
    }

    func update(_ preset: Preset) {
        guard let token = currentServerToken else { return }
        var all = allEntries()
        if let idx = all.firstIndex(where: { $0.preset.id == preset.id }) {
            all[idx] = PresetEntry(serverToken: token, preset: preset)
        }
        saveEntries(all)
        presets = presetsForToken(token)
    }

    func remove(_ preset: Preset) {
        guard let token = currentServerToken else { return }
        var all = allEntries()
        all.removeAll { $0.preset.id == preset.id }
        saveEntries(all)
        presets = presetsForToken(token)
    }

    // MARK: - Private

    private struct PresetEntry: Codable {
        let serverToken: String
        let preset: Preset
    }

    private func presetsForToken(_ token: String) -> [Preset] {
        allEntries().filter { $0.serverToken == token }.map(\.preset)
    }

    private func allEntries() -> [PresetEntry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([PresetEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveEntries(_ entries: [PresetEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
