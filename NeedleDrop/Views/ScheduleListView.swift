import SwiftUI

/// List of all playback schedules with enable/disable toggles.
struct ScheduleListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedules")
                .font(.headline)

            if appState.schedules.isEmpty {
                Text("No schedules yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.schedules) { schedule in
                            Button {
                                appState.scheduleNav = .edit(schedule)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(schedule.name)
                                            .font(.body)
                                        Text(schedule.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let station = schedule.favoriteTitle {
                                            Text(station)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }

                                    Spacer()

                                    // Enable/disable toggle
                                    Circle()
                                        .fill(schedule.enabled ? Color.green : Color.gray.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HoverRowButtonStyle())

                            if schedule.id != appState.schedules.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 250)
            }

            HStack {
                Button {
                    appState.scheduleNav = .create
                } label: {
                    Label("New Schedule", systemImage: "plus")
                }

                Spacer()
                Button("Done") { appState.scheduleNav = nil }
            }
        }
        .padding(16)
        .frame(width: 300)
        .task {
            await appState.loadSchedules()
        }
    }
}
