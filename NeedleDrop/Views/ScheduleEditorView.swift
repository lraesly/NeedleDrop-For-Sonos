import SwiftUI
import os

private let log = Logger(subsystem: "com.needledrop", category: "ScheduleEditor")

struct ScheduleEditorView: View {
    enum Mode: Equatable {
        case create
        case createFromPreset(Preset)
        case edit(PlaybackSchedule)
    }

    @EnvironmentObject var appState: AppState

    let mode: Mode

    @State private var name: String
    @State private var selectedFavorite: FavoriteItem?
    @State private var selectedRooms: Set<String>
    @State private var coordinatorRoom: String
    @State private var includeVolume: Bool
    @State private var volumeLevel: Double
    @State private var startDate: Date
    @State private var stopDate: Date
    @State private var hasStopTime: Bool
    @State private var selectedDays: Set<Int>
    @State private var enabled: Bool
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var editingScheduleId: String?
    @State private var serverRooms: [String] = []

    init(mode: Mode) {
        self.mode = mode

        switch mode {
        case .edit(let schedule):
            _name = State(initialValue: schedule.name)
            _selectedFavorite = State(initialValue: nil)
            _selectedRooms = State(initialValue: Set(schedule.rooms ?? []))
            _coordinatorRoom = State(initialValue: schedule.coordinatorRoom ?? "")
            _includeVolume = State(initialValue: schedule.volume != nil)
            _volumeLevel = State(initialValue: Double(schedule.volume ?? 50))
            _startDate = State(initialValue: Self.timeStringToDate(schedule.startTime))
            _stopDate = State(initialValue: Self.timeStringToDate(schedule.stopTime ?? "09:00"))
            _hasStopTime = State(initialValue: schedule.stopTime != nil)
            _selectedDays = State(initialValue: Set(schedule.days))
            _enabled = State(initialValue: schedule.enabled)
            _editingScheduleId = State(initialValue: schedule.id)

        case .createFromPreset(let preset):
            _name = State(initialValue: preset.name)
            _selectedFavorite = State(initialValue: nil)
            _selectedRooms = State(initialValue: Set(preset.rooms))
            _coordinatorRoom = State(initialValue: preset.coordinatorRoom)
            _includeVolume = State(initialValue: preset.volume != nil)
            _volumeLevel = State(initialValue: Double(preset.volume ?? 50))
            _startDate = State(initialValue: Self.timeStringToDate("07:00"))
            _stopDate = State(initialValue: Self.timeStringToDate("09:00"))
            _hasStopTime = State(initialValue: false)
            _selectedDays = State(initialValue: Set([0, 1, 2, 3, 4])) // weekdays
            _enabled = State(initialValue: true)

        case .create:
            _name = State(initialValue: "")
            _selectedFavorite = State(initialValue: nil)
            _selectedRooms = State(initialValue: [])
            _coordinatorRoom = State(initialValue: "")
            _includeVolume = State(initialValue: false)
            _volumeLevel = State(initialValue: 50)
            _startDate = State(initialValue: Self.timeStringToDate("07:00"))
            _stopDate = State(initialValue: Self.timeStringToDate("09:00"))
            _hasStopTime = State(initialValue: false)
            _selectedDays = State(initialValue: Set([0, 1, 2, 3, 4]))
            _enabled = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Schedule" : "New Schedule")
                .font(.headline)

            // Name
            TextField("Schedule Name", text: $name)
                .textFieldStyle(.roundedBorder)

            // Station picker
            Text("Station")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Station", selection: $selectedFavorite) {
                Text("Select a station...").tag(nil as FavoriteItem?)
                if !appState.customStationStore.stations.isEmpty {
                    Section("Custom Stations") {
                        ForEach(appState.customStationStore.stations) { station in
                            Text(station.name).tag(station.asFavoriteItem as FavoriteItem?)
                        }
                    }
                }
                Section("Sonos Favorites") {
                    ForEach(appState.favorites) { fav in
                        Text(fav.title).tag(fav as FavoriteItem?)
                    }
                }
            }
            .labelsHidden()

            // Room checkboxes
            Text("Rooms")
                .font(.caption)
                .foregroundStyle(.secondary)

            let topologyRooms = Set(appState.allTopologySpeakers.map(\.roomName))
            let baseRooms = topologyRooms.isEmpty ? Set(serverRooms) : topologyRooms
            let allRooms = baseRooms.union(selectedRooms).sorted()

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
            .frame(height: 130)

            // Primary room picker
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

            // Time pickers
            HStack {
                Text("Start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $startDate, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(width: 90)
            }

            Toggle("Auto-stop", isOn: $hasStopTime)
                .toggleStyle(.checkbox)

            if hasStopTime {
                HStack {
                    Text("Stop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $stopDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 90)
                }
            }

            // Days of week
            Text("Days")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { day in
                    Button {
                        if selectedDays.contains(day) {
                            selectedDays.remove(day)
                        } else {
                            selectedDays.insert(day)
                        }
                    } label: {
                        Text(PlaybackSchedule.dayLabels[day].prefix(1))
                            .font(.caption)
                            .fontWeight(selectedDays.contains(day) ? .bold : .regular)
                            .frame(width: 28, height: 28)
                            .background(
                                selectedDays.contains(day)
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear
                            )
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Quick-select buttons
            HStack(spacing: 8) {
                Button("Weekdays") { selectedDays = Set([0, 1, 2, 3, 4]) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Weekends") { selectedDays = Set([5, 6]) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Every day") { selectedDays = Set(0..<7) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if isEditing {
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.checkbox)
            }

            Divider()

            // Action buttons
            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        deleteSchedule()
                    }

                    Button("Test") {
                        testSchedule()
                    }
                    .disabled(isTesting)
                }

                Spacer()

                Button("Cancel") { appState.scheduleNav = nil }

                Button(isEditing ? "Save" : "Create") {
                    saveSchedule()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { matchFavorite() }
        .task { await loadServerRooms() }
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
            && !selectedDays.isEmpty
    }

    private func matchFavorite() {
        switch mode {
        case .edit(let schedule):
            selectedFavorite = appState.favorites.first(where: { $0.uri == schedule.favoriteUri })
                ?? appState.customStationStore.stations.first(where: { $0.streamURL == schedule.favoriteUri })?.asFavoriteItem
        case .createFromPreset(let preset):
            selectedFavorite = appState.favorites.first(where: { $0.uri == preset.favorite.uri })
                ?? appState.customStationStore.stations.first(where: { $0.streamURL == preset.favorite.uri })?.asFavoriteItem
        case .create:
            break
        }
    }

    private func saveSchedule() {
        guard let fav = selectedFavorite else { return }
        isSaving = true

        let coordinator = coordinatorRoom.isEmpty
            ? selectedRooms.sorted().first ?? ""
            : coordinatorRoom

        let schedule = PlaybackSchedule(
            id: editingScheduleId ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            enabled: enabled,
            favoriteTitle: fav.title,
            favoriteUri: fav.uri,
            favoriteMeta: fav.meta,
            rooms: Array(selectedRooms).sorted(),
            coordinatorRoom: coordinator,
            volume: includeVolume ? Int(volumeLevel) : nil,
            startTime: Self.dateToTimeString(startDate),
            stopTime: hasStopTime ? Self.dateToTimeString(stopDate) : nil,
            days: Array(selectedDays).sorted(),
            householdId: appState.currentHouseholdId
        )

        Task {
            do {
                if isEditing {
                    _ = try await appState.scheduleClient.updateSchedule(schedule)
                } else {
                    _ = try await appState.scheduleClient.createSchedule(schedule)
                }
                await appState.loadSchedules()
                appState.scheduleNav = .list
            } catch {
                log.error("Failed to save schedule: \(error.localizedDescription)")
            }
            isSaving = false
        }
    }

    private func deleteSchedule() {
        guard let id = editingScheduleId else { return }
        Task {
            do {
                try await appState.scheduleClient.deleteSchedule(id: id)
                await appState.loadSchedules()
                appState.scheduleNav = .list
            } catch {
                log.error("Failed to delete schedule: \(error.localizedDescription)")
            }
        }
    }

    private func testSchedule() {
        guard let id = editingScheduleId else { return }
        isTesting = true
        Task {
            do {
                try await appState.scheduleClient.testSchedule(id: id)
                log.info("Schedule test executed successfully")
            } catch {
                log.error("Failed to test schedule: \(error.localizedDescription)")
            }
            isTesting = false
        }
    }

    private func loadServerRooms() async {
        do {
            serverRooms = try await appState.scheduleClient.getSpeakerNames()
        } catch {
            log.error("Failed to load speakers from server: \(error.localizedDescription)")
        }
    }

    // MARK: - Time conversion

    static func timeStringToDate(_ time: String) -> Date {
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return Date()
        }
        let calendar = Calendar.current
        return calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }

    static func dateToTimeString(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
}
