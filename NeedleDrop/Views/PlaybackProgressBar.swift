import SwiftUI

/// A thin progress bar showing elapsed time, a track indicator, and remaining time.
///
/// Hidden automatically when `duration` is 0 (live streams, TV audio, or unknown).
struct PlaybackProgressBar: View {
    let position: Int   // seconds
    let duration: Int   // seconds

    /// Whether to show elapsed / remaining timestamps below the bar.
    var showTimestamps: Bool = true

    /// Optional color overrides for the mini player's transparent mode.
    var trackColor: Color = Color.secondary.opacity(0.2)
    var fillColor: Color = Color.accentColor
    var timeColor: Color = Color.secondary

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(trackColor)
                        .frame(height: 3)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fillColor)
                        .frame(width: progress * geometry.size.width, height: 3)
                }
            }
            .frame(height: 3)

            if showTimestamps {
                HStack {
                    Text(duration > 0 ? formatTime(position) : " ")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(timeColor)
                    Spacer()
                    Text(duration > 0 ? "-\(formatTime(max(duration - position, 0)))" : " ")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(timeColor)
                }
            }
        }
        .opacity(duration > 0 ? 1 : 0)
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return min(CGFloat(position) / CGFloat(duration), 1.0)
    }

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
