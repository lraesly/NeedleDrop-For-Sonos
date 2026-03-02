import SwiftUI

/// View for discovering and connecting to the remote NeedleDrop scrobbler.
struct ScrobblerConfigView: View {
    @EnvironmentObject var appState: AppState

    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let config = appState.scrobblerClient.config {
                // Connected
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.name)
                            .font(.system(size: 12))

                        Text("\(config.host):\(config.port)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Check") {
                        checkStatus()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Disconnect") {
                        appState.scrobblerClient.disconnect()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            } else {
                // Not connected
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(.tertiaryLabelColor))
                        .frame(width: 8, height: 8)

                    Text("Not connected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { appState.scrobblerClient.discoverScrobbler() }) {
                        if appState.scrobblerClient.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Discover")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appState.scrobblerClient.isSearching)
                }
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(isError ? .red : .green)
            }
        }
        .padding(.horizontal, 12)
    }

    private func checkStatus() {
        statusMessage = nil
        Task {
            do {
                let ok = try await appState.scrobblerClient.getStatus()
                statusMessage = ok ? "Connected — scrobbler running" : "Scrobbler not responding"
                isError = !ok
            } catch {
                statusMessage = error.localizedDescription
                isError = true
            }

            Task {
                try? await Task.sleep(for: .seconds(3))
                statusMessage = nil
            }
        }
    }
}
