import SwiftUI

/// Setup tab for speaker/zone preferences and mini player appearance.
struct SpeakerSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Default Zone
            if !appState.zones.isEmpty {
                sectionHeader("Default Zone")

                Picker("Default Zone", selection: Binding(
                    get: { appState.defaultZone ?? "__auto__" },
                    set: { appState.defaultZone = $0 == "__auto__" ? nil : $0 }
                )) {
                    Text("Auto (follow active)").tag("__auto__")
                    ForEach(appState.zones) { zone in
                        Text(zone.roomName).tag(zone.roomName)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                Divider().padding(.vertical, 4)
            }

            // Mini Player Appearance
            sectionHeader("Mini Player")

            Toggle("Show on launch", isOn: Binding(
                get: { appState.launchMiniPlayerOnStart },
                set: { appState.launchMiniPlayerOnStart = $0 }
            ))
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Toggle("Transparent overlay", isOn: Binding(
                get: { appState.isMiniPlayerTransparent },
                set: { appState.isMiniPlayerTransparent = $0 }
            ))
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            HStack {
                Text("Size")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Picker("Size", selection: Binding(
                    get: { appState.miniPlayerSize },
                    set: { appState.miniPlayerSize = $0 }
                )) {
                    Text("Compact").tag(MiniPlayerSize.compact)
                    Text("Large").tag(MiniPlayerSize.large)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Discovered speakers (informational)
            if !appState.speakers.isEmpty {
                Divider().padding(.vertical, 4)
                sectionHeader("Speakers")

                ForEach(appState.speakers) { speaker in
                    HStack(spacing: 8) {
                        Image(systemName: "hifispeaker.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Text(speaker.roomName)
                            .font(.system(size: 12))
                        Spacer()
                        Text(speaker.ip)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary.opacity(0.7))
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
