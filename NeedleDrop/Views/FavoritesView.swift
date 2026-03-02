import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !appState.favorites.isEmpty {
            Menu {
                ForEach(appState.favorites) { favorite in
                    Button {
                        appState.playFavorite(favorite)
                    } label: {
                        Text(favorite.title)
                    }
                }
            } label: {
                Label("Favorites", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
