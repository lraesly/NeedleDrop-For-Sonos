import SwiftUI

/// Picker for selecting the active Sonos zone (group).
struct ZonePickerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.zones.count > 1 {
            Picker("Zone", selection: Binding(
                get: { appState.selectedZone ?? "" },
                set: { appState.selectZone($0) }
            )) {
                ForEach(appState.zones) { zone in
                    HStack {
                        Text(zone.roomName)
                        if !zone.members.isEmpty {
                            Text("+\(zone.members.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(zone.coordinator.uuid)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } else if let zone = appState.zones.first {
            Text(zone.roomName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
