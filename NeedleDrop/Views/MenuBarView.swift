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
                VStack(spacing: 8) {
                    // Now playing placeholder (Phase 2)
                    VStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Now playing will appear here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding()

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
