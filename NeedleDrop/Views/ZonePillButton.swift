import SwiftUI
import os

private let log = Logger(subsystem: "com.needledrop", category: "ZonePillButton")

/// Pill-shaped button showing "● ZoneName ▾" that opens a popover
/// for zone switching and speaker grouping.
struct ZonePillButton: View {
    @EnvironmentObject var appState: AppState
    @State private var showingPopover = false
    @State private var showingGrouping = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(activeZoneName)
                    .font(.caption)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            if showingGrouping {
                speakerGroupingView
            } else {
                zoneListView
            }
        }
        .onChange(of: showingPopover) { isShowing in
            if !isShowing {
                // Reset to zone list when popover closes
                showingGrouping = false
            }
        }
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        switch appState.connectionState {
        case .connected: return .green
        case .discovering: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var activeZoneName: String {
        appState.activeZone?.roomName ?? "No Zone"
    }

    // MARK: - Zone List

    private var zoneListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.zones) { zone in
                Button {
                    appState.selectZone(zone.coordinator.uuid)
                    showingPopover = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: zone.coordinator.uuid == appState.selectedZone
                              ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                            .foregroundColor(zone.coordinator.uuid == appState.selectedZone
                                             ? .accentColor : .secondary)

                        Text(zone.roomName)
                            .font(.callout)

                        if !zone.members.isEmpty {
                            Text("+\(zone.members.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if zone.coordinator.uuid == appState.selectedZone
                            && appState.nowPlaying.transportState == .playing {
                            Image(systemName: "music.note")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .padding(.vertical, 4)

            Button {
                showingGrouping = true
            } label: {
                Label("Group Speakers\u{2026}", systemImage: "speaker.wave.2.fill")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(width: 220)
    }

    // MARK: - Speaker Grouping

    private var speakerGroupingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back button
            Button {
                showingGrouping = false
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                    Text("Playing to \(appState.activeZone?.roomName ?? "...")")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 4)

            // All speakers with checkboxes
            ForEach(sortedSpeakers, id: \.uuid) { speaker in
                let isCoordinator = speaker.uuid == appState.activeZone?.coordinator.uuid
                let isInGroup = isCoordinator || isMemberOfActiveZone(speaker)

                HStack {
                    Toggle(isOn: Binding(
                        get: { isInGroup },
                        set: { shouldJoin in
                            if shouldJoin {
                                log.info("Grouping \(speaker.roomName) with active zone")
                                appState.joinSpeaker(speaker.uuid)
                            } else if !isCoordinator {
                                log.info("Ungrouping \(speaker.roomName) from active zone")
                                appState.unjoinSpeaker(speaker)
                            }
                        }
                    )) {
                        HStack(spacing: 4) {
                            Text(speaker.roomName)
                                .font(.callout)
                            if isCoordinator {
                                Text("primary")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isCoordinator)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }

            Divider()
                .padding(.vertical, 4)

            HStack {
                Spacer()
                Button("Done") {
                    showingGrouping = false
                    showingPopover = false
                }
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 8)
        .frame(width: 240)
    }

    // MARK: - Helpers

    /// All visible speakers from zone topology, sorted by room name.
    /// Uses topology (not SSDP discovery) so all speakers appear even before
    /// UPnP services are loaded — and invisible/bonded devices are already filtered.
    private var sortedSpeakers: [SonosDevice] {
        appState.allTopologySpeakers.sorted { $0.roomName < $1.roomName }
    }

    private func isMemberOfActiveZone(_ speaker: SonosDevice) -> Bool {
        appState.activeZone?.members.contains(where: { $0.uuid == speaker.uuid }) ?? false
    }
}
