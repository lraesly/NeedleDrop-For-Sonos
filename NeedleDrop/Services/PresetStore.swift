import Foundation
import os

private let log = Logger(subsystem: "com.needledrop", category: "PresetStore")

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

    /// [Audit fix #9: decode errors are now logged instead of silently returning empty]
    private func loadPresets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([Preset].self, from: data)
        } catch {
            log.error("Failed to decode presets: \(error.localizedDescription)")
            return []
        }
    }

    /// [Audit fix #4: encode errors are now logged instead of silently dropping changes]
    private func save() {
        do {
            let data = try JSONEncoder().encode(presets)
            UserDefaults.standard.set(data, forKey: storeKey)
        } catch {
            log.error("Failed to encode presets: \(error.localizedDescription)")
        }
    }
}
