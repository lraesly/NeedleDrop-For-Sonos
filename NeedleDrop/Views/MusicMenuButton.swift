import SwiftUI

/// Pill-shaped "♪ ▾" button that opens a sectioned Menu combining
/// Favorites, Presets, and preset management actions.
struct MusicMenuButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            // -- Favorites Section --
            if !appState.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(appState.favorites) { favorite in
                        Button(favorite.title) {
                            appState.playFavorite(favorite)
                        }
                    }
                }
            }

            // -- Presets Section --
            if !appState.presetStore.presets.isEmpty {
                Section("Presets") {
                    ForEach(appState.presetStore.presets) { preset in
                        Button {
                            appState.activatePreset(preset)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text(presetSubtitle(preset))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            // -- Actions --
            Button {
                saveCurrentAsPreset()
            } label: {
                Label("Save What\u{2019}s Playing\u{2026}",
                      systemImage: "plus.square.on.square")
            }
            .disabled(appState.nowPlaying.track == nil)

            Button {
                appState.presetNav = .create
            } label: {
                Label("New Preset\u{2026}", systemImage: "plus")
            }

            Button {
                appState.presetNav = .list
            } label: {
                Label("Manage Presets\u{2026}", systemImage: "list.bullet")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.caption)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Helpers

    private func presetSubtitle(_ preset: Preset) -> String {
        var roomPart: String
        if preset.rooms.count == 1 {
            roomPart = preset.rooms.first ?? ""
        } else {
            roomPart = "\(preset.coordinatorRoom) +\(preset.rooms.count - 1)"
        }
        if let vol = preset.volume {
            roomPart += " \u{2022} \(vol)%"
        }
        return "\(preset.favorite.title) \u{2022} \(roomPart)"
    }

    private func saveCurrentAsPreset() {
        guard let track = appState.nowPlaying.track else { return }
        let zone = appState.activeZone
        let rooms = zone.map { [$0.coordinator.roomName] + $0.members.map(\.roomName) }
            ?? [appState.nowPlaying.zoneName ?? ""]
        let coordinator = zone?.coordinator.roomName
            ?? appState.nowPlaying.zoneName ?? ""
        appState.presetNav = .createFromCurrent(
            rooms: rooms,
            coordinatorRoom: coordinator,
            sourceUri: track.sourceURI
        )
    }
}
