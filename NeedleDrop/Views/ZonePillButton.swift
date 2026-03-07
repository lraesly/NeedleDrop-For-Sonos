import SwiftUI
import os

private let log = Logger(subsystem: "com.needledrop", category: "ZonePillButton")

/// Pill-shaped button showing "● ZoneName ▾" that opens a popover
/// for zone switching and speaker grouping.
struct ZonePillButton: View {
    @EnvironmentObject var appState: AppState
    @State private var showingPopover = false
    @State private var showingGrouping = false
    /// Pending group membership (speaker UUIDs) — applied on "Done".
    @State private var pendingGroup: Set<String> = []
    /// Per-speaker volumes fetched when grouping view opens.
    @State private var speakerVolumes: [String: Int] = [:]

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
        .onChange(of: showingGrouping) { isGrouping in
            if isGrouping {
                // Seed pending group from current zone state
                seedPendingGroup()
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
        guard let zone = appState.activeZone else { return "No Zone" }
        if zone.members.isEmpty {
            return zone.roomName
        }
        return "\(zone.roomName) +\(zone.members.count)"
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
                .buttonStyle(HoverRowButtonStyle())
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
            .buttonStyle(HoverRowButtonStyle())
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
            .buttonStyle(HoverButtonStyle())

            Divider()
                .padding(.vertical, 4)

            // All speakers with checkboxes and volume sliders
            ForEach(sortedSpeakers, id: \.uuid) { speaker in
                let isCoordinator = speaker.uuid == appState.activeZone?.coordinator.uuid

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { pendingGroup.contains(speaker.uuid) },
                            set: { selected in
                                if selected {
                                    pendingGroup.insert(speaker.uuid)
                                    // Fetch volume for newly checked speaker
                                    Task {
                                        if let vol = await appState.getVolumeForSpeaker(speaker.uuid) {
                                            speakerVolumes[speaker.uuid] = vol
                                        }
                                    }
                                } else if !isCoordinator {
                                    pendingGroup.remove(speaker.uuid)
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

                    // Volume slider for checked speakers
                    if pendingGroup.contains(speaker.uuid) {
                        speakerVolumeSlider(for: speaker)
                            .padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }

            Divider()
                .padding(.vertical, 4)

            HStack {
                Spacer()
                Button("Done") {
                    applyGroupChanges()
                    showingGrouping = false
                    showingPopover = false
                }
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 8)
        .frame(width: 260)
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

    /// Seed pendingGroup from the current active zone's coordinator + members,
    /// and fetch per-speaker volumes.
    private func seedPendingGroup() {
        guard let zone = appState.activeZone else { return }
        var group: Set<String> = [zone.coordinator.uuid]
        for member in zone.members {
            group.insert(member.uuid)
        }
        pendingGroup = group
        fetchSpeakerVolumes()
    }

    /// Fetch volumes for all speakers in parallel.
    private func fetchSpeakerVolumes() {
        let speakers = sortedSpeakers
        Task {
            await withTaskGroup(of: (String, Int?).self) { group in
                for speaker in speakers {
                    group.addTask {
                        let vol = await appState.getVolumeForSpeaker(speaker.uuid)
                        return (speaker.uuid, vol)
                    }
                }
                for await (uuid, vol) in group {
                    if let vol {
                        await MainActor.run {
                            speakerVolumes[uuid] = vol
                        }
                    }
                }
            }
        }
    }

    /// Compact volume slider for an individual speaker.
    private func speakerVolumeSlider(for speaker: SonosDevice) -> some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon(for: speakerVolumes[speaker.uuid] ?? 0))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 12)

            Slider(
                value: Binding(
                    get: { Double(speakerVolumes[speaker.uuid] ?? 0) },
                    set: { newVal in
                        let level = Int(newVal)
                        speakerVolumes[speaker.uuid] = level
                        appState.setVolumeForSpeaker(speaker.uuid, level: level)
                    }
                ),
                in: 0...100,
                step: 1
            )
            .controlSize(.mini)

            Text("\(speakerVolumes[speaker.uuid] ?? 0)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    private func volumeIcon(for level: Int) -> String {
        if level == 0 { return "speaker.slash.fill" }
        if level < 33 { return "speaker.wave.1.fill" }
        if level < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Diff pendingGroup against the current zone, apply all join/unjoin SOAP calls,
    /// then poll until zone topology reflects the changes.
    private func applyGroupChanges() {
        guard let zone = appState.activeZone else { return }

        // Current group UUIDs
        var currentGroup: Set<String> = [zone.coordinator.uuid]
        for member in zone.members {
            currentGroup.insert(member.uuid)
        }

        let toJoin = pendingGroup.subtracting(currentGroup)
        let toUnjoin = currentGroup.subtracting(pendingGroup).subtracting([zone.coordinator.uuid])

        guard !toJoin.isEmpty || !toUnjoin.isEmpty else { return }

        let speakers = appState.allTopologySpeakers
        let coordinatorUUID = zone.coordinator.uuid
        let expectedGroup = pendingGroup

        Task {
            // Send all SOAP commands sequentially
            for uuid in toJoin {
                if let speaker = speakers.first(where: { $0.uuid == uuid }) {
                    log.info("Grouping \(speaker.roomName) with active zone")
                    await appState.zoneManager.joinSpeaker(
                        speakerIP: speaker.ip,
                        toCoordinatorUUID: coordinatorUUID
                    )
                }
            }
            for uuid in toUnjoin {
                if let speaker = speakers.first(where: { $0.uuid == uuid }) {
                    log.info("Ungrouping \(speaker.roomName) from active zone")
                    await appState.zoneManager.unjoinSpeaker(speakerIP: speaker.ip)
                }
            }

            // Poll until Sonos topology reflects the expected group
            await appState.refreshZones(
                expectingCoordinator: coordinatorUUID,
                withMembers: expectedGroup
            )
        }
    }
}
