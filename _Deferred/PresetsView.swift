import SwiftUI

struct PresetsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            // Preset buttons — one tap to activate
            ForEach(appState.presetStore.presets) { preset in
                Button {
                    appState.activatePreset(preset)
                } label: {
                    VStack(alignment: .leading) {
                        Text(preset.name)
                        Text("\(preset.favorite.title) \u{2022} \(roomSummary(preset))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !appState.presetStore.presets.isEmpty {
                Divider()
            }

            // Save what's playing as a preset
            if appState.nowPlaying?.track != nil {
                Button {
                    saveCurrentAsPreset()
                } label: {
                    Label("Save What\u{2019}s Playing\u{2026}", systemImage: "plus.square.on.square")
                }
            }

            // Create new (blank)
            Button {
                appState.presetNav = .create
            } label: {
                Label("New Preset\u{2026}", systemImage: "plus")
            }

            // Edit existing (only if there are presets)
            if !appState.presetStore.presets.isEmpty {
                Button {
                    appState.presetNav = .list
                } label: {
                    Label("Edit Presets\u{2026}", systemImage: "pencil")
                }
            }
        } label: {
            Label("Presets", systemImage: "dial.low.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func roomSummary(_ preset: Preset) -> String {
        var summary: String
        if preset.rooms.count == 1 {
            summary = preset.rooms.first ?? ""
        } else {
            summary = "\(preset.coordinatorRoom) +\(preset.rooms.count - 1)"
        }
        if let vol = preset.volume {
            summary += " \u{2022} \(vol)%"
        }
        return summary
    }

    private func saveCurrentAsPreset() {
        guard let track = appState.nowPlaying?.track else { return }
        let zoneName = appState.selectedZone ?? track.zone
        let zone = appState.zones.first(where: { $0.name == zoneName })
        let rooms = zone?.members ?? [zoneName]
        let coordinator = zone?.name ?? zoneName
        appState.presetNav = .createFromCurrent(
            rooms: rooms,
            coordinatorRoom: coordinator,
            sourceUri: track.sourceUri
        )
    }
}

/// Inline list of all presets for editing/deleting.
struct PresetListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Presets")
                .font(.headline)

            if appState.presetStore.presets.isEmpty {
                Text("No presets yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(appState.presetStore.presets) { preset in
                        Button {
                            appState.presetNav = .edit(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.body)
                                Text("\(preset.favorite.title) \u{2022} \(preset.rooms.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Spacer()
                Button("Done") { appState.presetNav = nil }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
