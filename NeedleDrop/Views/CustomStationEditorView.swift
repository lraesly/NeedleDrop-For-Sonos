import SwiftUI
import os

private let log = Logger(subsystem: "com.needledrop", category: "CustomStationEditor")

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
    @State private var isLooking = false
    @State private var lookupFailed = false

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

            HStack {
                TextField("Station Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                Button {
                    lookupStation()
                } label: {
                    if isLooking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isLooking)
                .help("Look up on TuneIn")
            }

            if lookupFailed {
                Text("No match found on TuneIn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .frame(width: 300)
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

    // MARK: - TuneIn Lookup

    private func lookupStation() {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isLooking = true
        lookupFailed = false

        Task {
            defer { isLooking = false }

            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://opml.radiotime.com/Search.ashx?query=\(encoded)&render=json") else {
                lookupFailed = true
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = json["body"] as? [[String: Any]] else {
                    log.info("TuneIn lookup: unexpected response format")
                    lookupFailed = true
                    return
                }

                // Find the first station result
                guard let station = body.first(where: { $0["item"] as? String == "station" }) else {
                    log.info("TuneIn lookup: no station found for '\(query)'")
                    lookupFailed = true
                    return
                }

                let stationName = station["text"] as? String ?? "?"
                let guideId = station["guide_id"] as? String
                let image = station["image"] as? String
                log.info("TuneIn lookup: found '\(stationName)' (id: \(guideId ?? "?"))")

                // Auto-fill art URL if empty
                if artURL.trimmingCharacters(in: .whitespaces).isEmpty, let image {
                    // Use larger logo variant (logod vs logoq)
                    artURL = image.replacingOccurrences(of: "q.png", with: "d.png")
                }

                // Auto-fill stream URL if empty
                if streamURL.trimmingCharacters(in: .whitespaces).isEmpty, let guideId {
                    if let streamResult = await fetchTuneInStream(id: guideId) {
                        streamURL = streamResult
                    }
                }
            } catch {
                log.error("TuneIn lookup failed: \(error)")
                lookupFailed = true
            }
        }
    }

    private func fetchTuneInStream(id: String) async -> String? {
        guard let url = URL(string: "https://opml.radiotime.com/Tune.ashx?id=\(id)&render=json") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? [[String: Any]],
                  let streamURL = body.first?["url"] as? String else {
                return nil
            }
            return streamURL
        } catch {
            log.error("TuneIn stream fetch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
