import SwiftUI

@main
struct NeedleDropApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .frame(width: 360)
        } label: {
            Image(appState.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
