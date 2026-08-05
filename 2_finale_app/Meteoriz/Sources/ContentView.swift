import SwiftUI

struct ContentView: View {
    @StateObject private var diagnostics = DiagnosticsLog()
    @StateObject private var refreshState = RefreshState()
    @State private var showDebugLog = false

    var body: some View {
        ZStack(alignment: .top) {
            // Bewusst bildschirmfüllend (auch unter Statusleiste/Dynamic Island und
            // Home-Indicator) – die Seite selbst kennt via env(safe-area-inset-*) in
            // ihrem eigenen CSS den sicheren Bereich und polstert dort ab. Das vermeidet
            // die zweischichtige Lösung (native Hintergrundfarbe + WebView-Rand), bei der
            // während des Scrollens kurz Schwarz statt der Hintergrundfarbe durchschlug.
            WeatherWebView(diagnostics: diagnostics, refreshState: refreshState)
                .ignoresSafeArea()

            if refreshState.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                    Text("Aktualisiere…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.4), in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: refreshState.isRefreshing)
            }

            if let entry = diagnostics.bannerEntry {
                ErrorBannerView(entry: entry) {
                    diagnostics.dismissBanner()
                } onOpenLog: {
                    diagnostics.dismissBanner()
                    showDebugLog = true
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.25), value: diagnostics.bannerEntry?.id)
            }

            // Dezenter, kaum sichtbarer Zugang zum vollständigen Debug-Log – nur für
            // Support/Entwicklung gedacht, stört Endnutzer im Alltag nicht.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showDebugLog = true
                    } label: {
                        Image(systemName: "ladybug")
                            .font(.system(size: 13))
                            .padding(10)
                    }
                    .foregroundStyle(.white.opacity(0.12))
                }
            }
        }
        .background(
            // .ignoresSafeArea() nur auf der Hintergrundfarbe (nicht auf dem ganzen
            // ZStack), damit sie auch hinter Statusleiste/Dynamic Island und der
            // Home-Indicator-Zone durchscheint, während der eigentliche Inhalt weiter
            // innerhalb der sicheren Bereiche bleibt.
            Color(red: 6/255, green: 8/255, blue: 13/255).ignoresSafeArea()
        )
        .sheet(isPresented: $showDebugLog) {
            DebugLogView(diagnostics: diagnostics)
        }
    }
}

#Preview {
    ContentView()
}
