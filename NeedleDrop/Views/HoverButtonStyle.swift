import SwiftUI

// MARK: - Icon Button Hover Style

/// Button style that shows a subtle rounded-rect highlight on hover
/// and dims on press. For icon buttons (transport, footer, heart, mute).
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonContent(configuration: configuration)
    }
}

private struct HoverButtonContent: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Row Button Hover Style

/// Button style that shows a full-width row highlight on hover.
/// For list items (zone list, preset list, "Group Speakers" row).
struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRowContent(configuration: configuration)
    }
}

private struct HoverRowContent: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                    .padding(.horizontal, -4)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
    }
}
