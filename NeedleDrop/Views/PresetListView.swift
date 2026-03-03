import SwiftUI

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
                Button {
                    appState.presetNav = .create
                } label: {
                    Label("New Preset", systemImage: "plus")
                }

                Spacer()
                Button("Done") { appState.presetNav = nil }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
