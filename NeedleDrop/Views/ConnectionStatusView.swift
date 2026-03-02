import SwiftUI

struct ConnectionStatusView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .connected: return .green
        case .discovering: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var statusText: String {
        switch appState.connectionState {
        case .connected: return "Connected"
        case .discovering: return "Discovering..."
        case .disconnected: return "Disconnected"
        case .error(let msg): return msg
        }
    }
}
