import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = "speakers"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                ConnectionStatusView()
                Spacer()
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
                    // Now playing
                    NowPlayingView()

                    Divider()

                    // Speaker list
                    SonosSetupView()
                }
            }

            Divider()

            // Footer
            HStack {
                Text("NeedleDrop v2")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
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
    }
}
