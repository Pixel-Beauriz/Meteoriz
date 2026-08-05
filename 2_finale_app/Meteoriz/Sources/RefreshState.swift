import Combine

/// Ob gerade ein manuelles Pull-to-Refresh läuft, für das kleine Overlay in ContentView.
final class RefreshState: ObservableObject {
    @Published var isRefreshing = false
}
