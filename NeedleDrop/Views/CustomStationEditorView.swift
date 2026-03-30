import SwiftUI

struct CustomStationEditorView: View {
    enum Mode: Equatable {
        case create
        case edit(CustomStation)
    }

    @EnvironmentObject var appState: AppState

    let mode: Mode

    @State private var name: String
    @State private var streamURL: String
    @State private var artURL: String

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _streamURL = State(initialValue: "")
            _artURL = State(initialValue: "")
        case .edit(let station):
            _name = State(initialValue: station.name)
            _streamURL = State(initialValue: station.streamURL)
            _artURL = State(initialValue: station.artURL ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Station" : "New Station")
                .font(.headline)

            TextField("Station Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Stream URL", text: $streamURL)
                .textFieldStyle(.roundedBorder)

            if !streamURL.isEmpty && !isValidURL {
                Text("Enter a valid http:// or https:// URL")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("Station Art URL (optional)", text: $artURL)
                .textFieldStyle(.roundedBorder)

            Divider()

            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        if case .edit(let station) = mode {
                            appState.customStationStore.remove(station)
                        }
                        appState.customStationNav = nil
                    }
                }

                Spacer()

                Button("Cancel") { appState.customStationNav = nil }

                Button(isEditing ? "Save" : "Create") {
                    saveStation()
                    appState.customStationNav = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Helpers

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isValidURL: Bool {
        let trimmed = streamURL.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && isValidURL
    }

    private func saveStation() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespaces)
        let trimmedArt = artURL.trimmingCharacters(in: .whitespaces)
        let art: String? = trimmedArt.isEmpty ? nil : trimmedArt

        if case .edit(let existing) = mode {
            let updated = CustomStation(id: existing.id, name: trimmedName, streamURL: trimmedURL, artURL: art)
            appState.customStationStore.update(updated)
        } else {
            let station = CustomStation(name: trimmedName, streamURL: trimmedURL, artURL: art)
            appState.customStationStore.add(station)
        }
    }
}
