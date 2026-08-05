import SwiftUI

struct ErrorBannerView: View {
    let entry: DiagnosticEntry
    let onDismiss: () -> Void
    let onOpenLog: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(entry.level == .error ? Color(red: 0.95, green: 0.4, blue: 0.4) : Color(red: 0.95, green: 0.7, blue: 0.29))

            VStack(alignment: .leading, spacing: 2) {
                Text(shortMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(entry.source)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)
            }

            Spacer(minLength: 8)

            Button("Details", action: onOpenLog)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.29, green: 0.95, blue: 0.78))

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var shortMessage: String {
        userFacingMessage(for: entry.message)
    }

    /// Übersetzt technische Fehler in eine kurze, verständliche Meldung für Endnutzer;
    /// die vollen technischen Details bleiben im Debug-Log (Details-Button) einsehbar.
    private func userFacingMessage(for raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("offline") || raw.localizedCaseInsensitiveContains("internet") || raw.localizedCaseInsensitiveContains("network") {
            return "Keine Internetverbindung – Wetterdaten nicht aktuell"
        }
        if raw.localizedCaseInsensitiveContains("standort") || raw.localizedCaseInsensitiveContains("location") {
            return "Standort nicht verfügbar"
        }
        return "Wetterdaten konnten nicht vollständig geladen werden"
    }
}
