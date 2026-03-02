import SwiftUI

/// View for discovering and displaying Sonos speakers on the network.
/// Replaces v1's ServerPickerView.
struct SonosSetupView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sonos Speakers")
                    .font(.headline)
                Spacer()
                if appState.discoveryService.isDiscovering {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
            }

            if appState.speakers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hifispeaker.2")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("Searching for Sonos speakers...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(appState.speakers) { speaker in
                    HStack {
                        Image(systemName: "hifispeaker.fill")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(speaker.roomName)
                                .font(.body)
                            Text(speaker.ip)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.vertical, 2)
                }

                Text("\(appState.speakers.count) speaker\(appState.speakers.count == 1 ? "" : "s") found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
