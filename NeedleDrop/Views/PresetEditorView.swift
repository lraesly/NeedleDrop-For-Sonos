import SwiftUI
import os

private let log = Logger(subsystem: "com.needledrop", category: "PresetEditor")

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

            // Use zone topology (filters invisible/bonded devices) and deduplicate by name
            let allRooms = Array(Set(appState.allTopologySpeakers.map(\.roomName))).sorted()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allRooms, id: \.self) { room in
                        Toggle(room, isOn: Binding(
                            get: { selectedRooms.contains(room) },
                            set: { isOn in
                                if isOn {
                                    selectedRooms.insert(room)
                                    if coordinatorRoom.isEmpty {
                                        coordinatorRoom = room
                                    }
                                } else {
                                    selectedRooms.remove(room)
                                    if coordinatorRoom == room {
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

    private func matchFavorite() {
        if case .edit(let preset) = mode {
            selectedFavorite = appState.favorites.first(where: { $0.uri == preset.favorite.uri })
        } else if !prefillRooms.isEmpty {
            // "Save What's Playing" — always use current volume
            volumeLevel = Double(appState.volume)

            // Collect URIs to try: source URI + enqueued URI (closer to favorite for radio)
            var urisToTry: [String] = []
            if let uri = prefillSourceUri { urisToTry.append(uri) }
            if let enqueued = appState.nowPlaying.enqueuedURI,
               !urisToTry.contains(enqueued) {
                urisToTry.append(enqueued)
            }

            log.info("Matching favorite — URIs to try: \(urisToTry)")
            log.info("Available favorites: \(appState.favorites.map { "\($0.title): \($0.uri.prefix(60))" })")

            // Try to match the playing source to a favorite by URI
            for uri in urisToTry {
                guard selectedFavorite == nil else { break }
                // 1. Exact URI match
                selectedFavorite = appState.favorites.first(where: { $0.uri == uri })
                if selectedFavorite != nil { log.info("Matched by exact URI"); break }
                // 2. Base URI match (strip query params)
                selectedFavorite = appState.favorites.first(where: { uriBase($0.uri) == uriBase(uri) })
                if selectedFavorite != nil { log.info("Matched by base URI"); break }
                // 3. Partial match (favorite URI contained in source or vice versa)
                let base = uriBase(uri)
                selectedFavorite = appState.favorites.first(where: {
                    base.contains(uriBase($0.uri)) || uriBase($0.uri).contains(base)
                })
                if selectedFavorite != nil { log.info("Matched by partial URI"); break }
            }

            // 4. Title-based fallback — match media/station title against favorite titles
            if selectedFavorite == nil, let mediaTitle = appState.nowPlaying.mediaTitle {
                log.info("URI matching failed, trying title match: '\(mediaTitle)'")
                selectedFavorite = appState.favorites.first(where: {
                    $0.title.localizedCaseInsensitiveCompare(mediaTitle) == .orderedSame
                })
                // Also try contains (e.g., "Underground Garage" matches "SXM Underground Garage")
                if selectedFavorite == nil {
                    selectedFavorite = appState.favorites.first(where: {
                        $0.title.localizedStandardContains(mediaTitle) ||
                        mediaTitle.localizedStandardContains($0.title)
                    })
                }
                if selectedFavorite != nil { log.info("Matched by title") }
            }

            if selectedFavorite == nil {
                log.warning("No favorite matched for current playback")
            }
        }
    }

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
