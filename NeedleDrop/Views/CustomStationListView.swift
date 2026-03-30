import SwiftUI

/// Inline list of user-defined stream stations with play and edit actions.
struct CustomStationListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Stations")
                .font(.headline)

            if appState.customStationStore.stations.isEmpty {
                Text("No custom stations yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.customStationStore.stations) { station in
                            HStack(spacing: 8) {
                                Button {
                                    appState.playFavorite(station.asFavoriteItem)
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Play")

                                Button {
                                    appState.customStationNav = .edit(station)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(station.name)
                                            .font(.body)
                                        Text(station.streamURL)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(HoverRowButtonStyle())
                            }
                            .padding(.vertical, 4)

                            if station.id != appState.customStationStore.stations.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Button {
                    appState.customStationNav = .create
                } label: {
                    Label("New Station", systemImage: "plus")
                }

                Spacer()
                Button("Done") { appState.customStationNav = nil }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
