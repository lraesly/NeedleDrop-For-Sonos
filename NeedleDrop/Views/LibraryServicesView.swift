import SwiftUI
import AppKit

/// Configuration view for Spotify and Apple Music library save integrations.
struct LibraryServicesView: View {
    @EnvironmentObject var appState: AppState

    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Spotify
            sectionHeader("Spotify")
            spotifySection

            Divider().padding(.vertical, 4)

            // Apple Music
            sectionHeader("Apple Music")
            appleMusicSection

            // Status messages
            if let error = errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            } else if let success = successMessage {
                Text(success)
                    .font(.caption2)
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Spotify

    private var spotifySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Client ID field
            if !appState.spotifyService.isConnected {
                TextField("Client ID", text: Binding(
                    get: { appState.spotifyService.clientId },
                    set: { appState.spotifyService.clientId = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
            }

            // Status + action
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.spotifyService.isConnected ? .green
                          : appState.spotifyService.hasClientId ? .orange
                          : Color(.tertiaryLabelColor))
                    .frame(width: 8, height: 8)

                Text(spotifyStatusText)
                    .font(.system(size: 12))
                    .foregroundStyle(appState.spotifyService.isConnected ? .primary : .secondary)

                Spacer()

                if appState.spotifyService.isConnected {
                    Button("Disconnect") {
                        appState.spotifyService.disconnect()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                } else if appState.spotifyService.hasClientId {
                    Button(action: connectSpotify) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Connect")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isConnecting)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var spotifyStatusText: String {
        if appState.spotifyService.isConnected { return "Connected" }
        if appState.spotifyService.hasClientId { return "Ready — click Connect to authorize" }
        return "Enter your Spotify Client ID"
    }

    // MARK: - Apple Music

    private var appleMusicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appleMusicStatusColor)
                    .frame(width: 8, height: 8)

                Text(appleMusicStatusText)
                    .font(.system(size: 12))
                    .foregroundStyle(
                        appState.appleMusicService.isConnected ? .primary : .secondary
                    )

                Spacer()

                if appState.appleMusicService.isConnected {
                    Button("Disconnect") {
                        appState.appleMusicService.disconnect()
                        appState.objectWillChange.send()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                } else if appState.appleMusicService.authorizationStatus == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Connect") {
                        Task {
                            await appState.appleMusicService.requestAuthorization()
                            appState.objectWillChange.send()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if appState.appleMusicService.authorizationStatus == .denied {
                Text("Grant access in System Settings → Privacy & Security → Media & Apple Music.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
    }

    private var appleMusicStatusColor: Color {
        let service = appState.appleMusicService
        if service.isConnected { return .green }
        if service.authorizationStatus == .denied { return .red }
        if service.authorizationStatus == .authorized { return .orange }
        return Color(.tertiaryLabelColor)
    }

    private var appleMusicStatusText: String {
        let service = appState.appleMusicService
        if service.isConnected { return "Connected" }
        if service.authorizationStatus == .denied { return "Access denied" }
        if service.authorizationStatus == .authorized && !service.isEnabled {
            return "Disabled"
        }
        return "Not connected"
    }

    // MARK: - Subviews

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary.opacity(0.7))
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Actions

    private func connectSpotify() {
        isConnecting = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await appState.spotifyService.authorize()
                isConnecting = false
                successMessage = "Spotify connected"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    successMessage = nil
                }
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
