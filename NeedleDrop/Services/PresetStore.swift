import Foundation

/// Persists presets to UserDefaults.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset] = []

    private let storeKey = "savedPresets_v2"

    init() {
        presets = loadPresets()
    }

    // MARK: - Mutations

    func add(_ preset: Preset) {
        presets.append(preset)
        save()
    }

    func update(_ preset: Preset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    func remove(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    // MARK: - Private

    private func loadPresets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
