import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header: connection status + zone picker
            HStack {
                ConnectionStatusView()
                Spacer()
                ZonePickerView()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Content
            if appState.speakers.isEmpty {
                SonosSetupView()
            } else {
                VStack(spacing: 0) {
                    // Now playing + controls
                    NowPlayingView()

                    // Favorites + Presets
                    if !appState.favorites.isEmpty || !appState.presetStore.presets.isEmpty {
                        Divider()

                        HStack {
                            if !appState.favorites.isEmpty {
                                FavoritesView()
                            }
                            if !appState.presetStore.presets.isEmpty || !appState.favorites.isEmpty {
                                PresetsView()
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }

            // Services (collapsible)
            if !appState.speakers.isEmpty {
                Divider()

                DisclosureGroup {
                    LibraryServicesView()

                    Divider().padding(.vertical, 4)

                    Text("Scrobbler")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 2)

                    ScrobblerConfigView()

                    if appState.scrobblerClient.config != nil {
                        ScrobbleFiltersView()
                    }
                } label: {
                    Text("Services")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()

            // Footer: mini player toggle, banner toggle, quit
            HStack(spacing: 12) {
                if !appState.speakers.isEmpty {
                    Button {
                        appState.toggleMiniPlayer()
                    } label: {
                        Image(systemName: appState.isMiniPlayerVisible
                              ? "pip.fill" : "pip")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help(appState.isMiniPlayerVisible ? "Hide Mini Player" : "Show Mini Player")

                    Button {
                        appState.isBannerEnabled.toggle()
                    } label: {
                        Image(systemName: appState.isBannerEnabled
                              ? "bell.fill" : "bell.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help(appState.isBannerEnabled ? "Disable Track Banners" : "Enable Track Banners")

                    if appState.isMiniPlayerVisible {
                        Button {
                            appState.isMiniPlayerTransparent.toggle()
                        } label: {
                            Image(systemName: appState.isMiniPlayerTransparent
                                  ? "sun.max" : "sun.max.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help(appState.isMiniPlayerTransparent ? "Solid Mode" : "Transparent Mode")
                    }
                }

                Spacer()

                Text("NeedleDrop v2")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .popover(isPresented: Binding(
            get: { appState.presetNav != nil },
            set: { if !$0 { appState.presetNav = nil } }
        )) {
            presetPopoverContent
        }
    }

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
