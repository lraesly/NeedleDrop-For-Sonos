import SwiftUI

struct PresetEditorView: View {
    enum Mode: Equatable {
        case create
        case edit(Preset)
    }

    @EnvironmentObject var appState: AppState

    let mode: Mode
    let prefillRooms: [String]
    let prefillCoordinator: String
    let prefillSourceUri: String?

    @State private var name: String
    @State private var selectedFavorite: FavoriteItem?
    @State private var selectedRooms: Set<String>
    @State private var coordinatorRoom: String
    @State private var includeVolume: Bool
    @State private var volumeLevel: Double

    init(mode: Mode, prefillRooms: [String] = [], prefillCoordinator: String = "", prefillSourceUri: String? = nil) {
        self.mode = mode
        self.prefillRooms = prefillRooms
        self.prefillCoordinator = prefillCoordinator
        self.prefillSourceUri = prefillSourceUri

        // Initialize @State at creation time so values are ready immediately.
        // selectedFavorite needs appState (not available in init) — set in onAppear.
        switch mode {
        case .edit(let preset):
            _name = State(initialValue: preset.name)
            _selectedFavorite = State(initialValue: nil)
            _selectedRooms = State(initialValue: Set(preset.rooms))
            _coordinatorRoom = State(initialValue: preset.coordinatorRoom)
            _includeVolume = State(initialValue: preset.volume != nil)
            _volumeLevel = State(initialValue: Double(preset.volume ?? 50))
        case .create where !prefillRooms.isEmpty:
            _name = State(initialValue: "")
            _selectedFavorite = State(initialValue: nil)
            _selectedRooms = State(initialValue: Set(prefillRooms))
            _coordinatorRoom = State(initialValue: prefillCoordinator.isEmpty
                ? (prefillRooms.sorted().first ?? "")
                : prefillCoordinator)
            _includeVolume = State(initialValue: true)
            _volumeLevel = State(initialValue: 50)
        case .create:
            _name = State(initialValue: "")
            _selectedFavorite = State(initialValue: nil)
            _selectedRooms = State(initialValue: [])
            _coordinatorRoom = State(initialValue: "")
            _includeVolume = State(initialValue: false)
            _volumeLevel = State(initialValue: 50)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Preset" : "New Preset")
                .font(.headline)

            // Name
            TextField("Preset Name", text: $name)
                .textFieldStyle(.roundedBorder)

            // Station picker
            Text("Station")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Station", selection: $selectedFavorite) {
                Text("Select a station...").tag(nil as FavoriteItem?)
                ForEach(appState.favorites) { fav in
                    Text(fav.title).tag(fav as FavoriteItem?)
                }
            }
            .labelsHidden()

            // Room checkboxes
            Text("Rooms")
                .font(.caption)
                .foregroundStyle(.secondary)

            let allSpeakers = appState.speakers.map(\.name).sorted()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allSpeakers, id: \.self) { speaker in
                        Toggle(speaker, isOn: Binding(
                            get: { selectedRooms.contains(speaker) },
                            set: { isOn in
                                if isOn {
                                    selectedRooms.insert(speaker)
                                    if coordinatorRoom.isEmpty {
                                        coordinatorRoom = speaker
                                    }
                                } else {
                                    selectedRooms.remove(speaker)
                                    if coordinatorRoom == speaker {
                                        coordinatorRoom = selectedRooms.sorted().first ?? ""
                                    }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 150)

            // Primary room picker (when 2+ rooms)
            if selectedRooms.count > 1 {
                Picker("Primary Room", selection: $coordinatorRoom) {
                    ForEach(Array(selectedRooms).sorted(), id: \.self) { room in
                        Text(room).tag(room)
                    }
                }
                .font(.caption)
            }

            // Volume
            Toggle("Set Volume", isOn: $includeVolume)
                .toggleStyle(.checkbox)

            if includeVolume {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                    Slider(value: $volumeLevel, in: 0...100, step: 1)
                    Text("\(Int(volumeLevel))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            Divider()

            // Action buttons
            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        if case .edit(let preset) = mode {
                            appState.presetStore.remove(preset)
                        }
                        appState.presetNav = nil
                    }
                }

                Spacer()

                Button("Cancel") { appState.presetNav = nil }

                Button(isEditing ? "Save" : "Create") {
                    savePreset()
                    appState.presetNav = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { matchFavorite() }
    }

    // MARK: - Helpers

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedFavorite != nil
            && !selectedRooms.isEmpty
    }

    /// Match a favorite by URI and prefill volume (needs appState, can't run in init).
    private func matchFavorite() {
        if case .edit(let preset) = mode {
            selectedFavorite = appState.favorites.first(where: { $0.uri == preset.favorite.uri })
        } else if let uri = prefillSourceUri {
            // "Save What's Playing" — match source URI against favorites.
            // Sonos transport URIs often differ from favorite URIs in query
            // params (e.g. flags=8200 vs flags=8232), so strip the query
            // string and compare the base URI path.
            selectedFavorite = appState.favorites.first(where: { $0.uri == uri })
                ?? appState.favorites.first(where: { uriBase($0.uri) == uriBase(uri) })
            // Prefill current volume so the slider is ready
            volumeLevel = appState.volume
        }
    }

    /// Strip query parameters from a Sonos URI for fuzzy matching.
    private func uriBase(_ uri: String) -> String {
        uri.components(separatedBy: "?").first ?? uri
    }

    private func savePreset() {
        guard let fav = selectedFavorite else { return }

        let presetFavorite = PresetFavorite(
            title: fav.title,
            uri: fav.uri,
            meta: fav.meta,
            albumArtUri: fav.albumArtUri
        )

        let coordinator = coordinatorRoom.isEmpty
            ? selectedRooms.sorted().first ?? ""
            : coordinatorRoom

        let vol = includeVolume ? Int(volumeLevel) : nil

        if case .edit(let existing) = mode {
            let updated = Preset(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespaces),
                favorite: presetFavorite,
                rooms: Array(selectedRooms).sorted(),
                coordinatorRoom: coordinator,
                volume: vol
            )
            appState.presetStore.update(updated)
        } else {
            let preset = Preset(
                name: name.trimmingCharacters(in: .whitespaces),
                favorite: presetFavorite,
                rooms: Array(selectedRooms).sorted(),
                coordinatorRoom: coordinator,
                volume: vol
            )
            appState.presetStore.add(preset)
        }
    }
}
