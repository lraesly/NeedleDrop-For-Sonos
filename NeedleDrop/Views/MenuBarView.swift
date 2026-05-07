import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSetup = false
    @State private var setupTab = 0
    @State private var newHomeName = ""
    @FocusState private var homeNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header: connection status + zone picker
            HStack {
                ZonePillButton()
                Spacer()
                MusicMenuButton()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Content
            if appState.speakers.isEmpty {
                SonosSetupView()
            } else if appState.pendingHomeNaming {
                homeNamingContent
            } else if showSetup {
                setupContent
            } else {
                mainContent
            }

            Divider()

            // Footer
            footer
        }
        .popover(isPresented: Binding(
            get: { appState.presetNav != nil },
            set: { if !$0 { DispatchQueue.main.async { appState.presetNav = nil } } }
        )) {
            presetPopoverContent
        }
        .popover(isPresented: Binding(
            get: { appState.scheduleNav != nil },
            set: { if !$0 { DispatchQueue.main.async { appState.scheduleNav = nil } } }
        )) {
            schedulePopoverContent
        }
        .popover(isPresented: Binding(
            get: { appState.customStationNav != nil },
            set: { if !$0 { DispatchQueue.main.async { appState.customStationNav = nil } } }
        )) {
            customStationPopoverContent
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        NowPlayingView()
    }

    // MARK: - Setup Content

    @ViewBuilder
    private var setupContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $setupTab) {
                Text("Speaker").tag(0)
                Text("Scrobbling").tag(1)
                Text("Services").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                switch setupTab {
                case 0:
                    SpeakerSettingsView()
                case 1:
                    scrobblingTab
                case 2:
                    LibraryServicesView()
                default:
                    EmptyView()
                }
            }
            .frame(minHeight: 300)
        }
    }

    @ViewBuilder
    private var scrobblingTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scrobbler")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ScrobblerConfigView()

            if appState.scrobblerClient.config != nil {
                Divider().padding(.vertical, 4)
                ScrobbleFiltersView()
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if !appState.speakers.isEmpty {
                // Mini player toggle
                Button {
                    appState.toggleMiniPlayer()
                } label: {
                    Image(systemName: appState.isMiniPlayerVisible
                          ? "pip.fill" : "pip")
                        .font(.caption)
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundColor(.secondary)
                .help(appState.isMiniPlayerVisible ? "Hide Mini Player" : "Show Mini Player")

                // Banner toggle
                Button {
                    appState.isBannerEnabled.toggle()
                } label: {
                    Image(systemName: appState.isBannerEnabled
                          ? "bell.fill" : "bell.slash")
                        .font(.caption)
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundColor(.secondary)
                .help(appState.isBannerEnabled ? "Song change popups: On" : "Song change popups: Off")

                // Custom stations
                Button {
                    appState.customStationNav = .list
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundColor(.secondary)
                .help("Custom Stations")

                // Schedule timer
                if appState.scrobblerClient.config != nil {
                    Button {
                        appState.scheduleNav = .list
                    } label: {
                        Image(systemName: "clock")
                            .font(.caption)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .foregroundColor(.secondary)
                    .help("Playback Schedules")
                }

                // Setup toggle (gear icon / "Done" text)
                Button {
                    showSetup.toggle()
                    if !showSetup { setupTab = 0 }
                } label: {
                    if showSetup {
                        Text("Done")
                            .font(.caption)
                    } else {
                        Image(systemName: "gearshape")
                            .font(.caption)
                    }
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundColor(showSetup ? .accentColor : .secondary)
                .help(showSetup ? "Close Setup" : "Setup")
            }

            Spacer()

            Toggle("Add", isOn: $appState.autoAddToAppleMusic)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption2)
                .disabled(!appState.appleMusicService.isConnected)
                .help(appState.appleMusicService.isConnected
                      ? "Auto-add resolved tracks to your Apple Music library. Resets when zone or station changes."
                      : "Connect Apple Music in Setup to enable auto-add")

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(HoverButtonStyle())
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Home Naming

    @ViewBuilder
    private var homeNamingContent: some View {
        VStack(spacing: 12) {
            Text("Name This Home")
                .font(.headline)

            Text("Give this Sonos system a name so presets can be organized by home.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField("e.g. Bethesda, Beach House", text: $newHomeName)
                .textFieldStyle(.roundedBorder)
                .focused($homeNameFieldFocused)
                .onSubmit { saveHomeName() }

            HStack {
                Button("Skip") { saveHomeName() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)

                Spacer()

                Button("Save") { saveHomeName() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .onAppear { homeNameFieldFocused = true }
    }

    private func saveHomeName() {
        guard let id = appState.currentHouseholdId else { return }
        let trimmed = newHomeName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty
            ? "Home \(appState.homeStore.homes.count + 1)"
            : trimmed
        appState.homeStore.addHome(householdId: id, name: name)
        newHomeName = ""
        appState.pendingHomeNaming = false
    }

    // MARK: - Schedule Popover

    @ViewBuilder
    private var schedulePopoverContent: some View {
        switch appState.scheduleNav {
        case .list:
            ScheduleListView()
                .environmentObject(appState)
        case .create:
            ScheduleEditorView(mode: .create)
                .environmentObject(appState)
        case .createFromPreset(let preset):
            ScheduleEditorView(mode: .createFromPreset(preset))
                .environmentObject(appState)
        case .edit(let schedule):
            ScheduleEditorView(mode: .edit(schedule))
                .environmentObject(appState)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Custom Station Popover

    @ViewBuilder
    private var customStationPopoverContent: some View {
        switch appState.customStationNav {
        case .list:
            CustomStationListView()
                .environmentObject(appState)
        case .create:
            CustomStationEditorView(mode: .create)
                .environmentObject(appState)
        case .edit(let station):
            CustomStationEditorView(mode: .edit(station))
                .environmentObject(appState)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Preset Popover

    @ViewBuilder
    private var presetPopoverContent: some View {
        switch appState.presetNav {
        case .list:
            PresetListView()
                .environmentObject(appState)
        case .create:
            PresetEditorView(mode: .create)
                .environmentObject(appState)
        case .edit(let preset):
            PresetEditorView(mode: .edit(preset))
                .environmentObject(appState)
        case .createFromCurrent(let rooms, let coordinator, let sourceUri):
            PresetEditorView(
                mode: .create,
                prefillRooms: rooms,
                prefillCoordinator: coordinator,
                prefillSourceUri: sourceUri
            )
            .environmentObject(appState)
        case nil:
            EmptyView()
        }
    }
}
