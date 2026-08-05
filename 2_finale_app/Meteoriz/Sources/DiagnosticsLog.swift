import Foundation
import Combine

struct DiagnosticEntry: Identifiable {
    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    let id = UUID()
    let date = Date()
    let level: Level
    let source: String
    let message: String
}

/// Sammelt technische Fehler (Netzwerk, WebView-Ladefehler, JS-Exceptions) für die
/// Fehleranzeige: aktuellster Fehler als dezentes Banner, komplette Historie im
/// Debug-Log (per Schütteln des Geräts erreichbar).
final class DiagnosticsLog: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published var bannerEntry: DiagnosticEntry?

    private let maxEntries = 200
    private var bannerDismissWorkItem: DispatchWorkItem?
    private var pendingBannerWorkItem: DispatchWorkItem?
    private static let bannerGracePeriod: TimeInterval = 2.5

    func log(_ level: DiagnosticEntry.Level, source: String, _ message: String) {
        let entry = DiagnosticEntry(level: level, source: source, message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            if level == .error || level == .warning {
                self.scheduleBanner(entry)
            }
        }
    }

    // Viele JS-Fehler (z.B. ein abgebrochener Request beim schnellen Pull-to-Refresh)
    // lösen sich innerhalb weniger Sekunden von selbst, wenn die Daten trotzdem laden.
    // Der Banner erscheint deshalb erst nach einer kurzen Gnadenfrist – meldet die
    // Seite in der Zwischenzeit per reportSuccess() einen erfolgreichen Datenload,
    // wird der Banner gar nicht erst gezeigt.
    private func scheduleBanner(_ entry: DiagnosticEntry) {
        pendingBannerWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showBanner(entry)
        }
        pendingBannerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerGracePeriod, execute: work)
    }

    func reportSuccess() {
        pendingBannerWorkItem?.cancel()
        pendingBannerWorkItem = nil
    }

    private func showBanner(_ entry: DiagnosticEntry) {
        bannerDismissWorkItem?.cancel()
        bannerEntry = entry
        let work = DispatchWorkItem { [weak self] in
            if self?.bannerEntry?.id == entry.id {
                self?.bannerEntry = nil
            }
        }
        bannerDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func dismissBanner() {
        pendingBannerWorkItem?.cancel()
        bannerDismissWorkItem?.cancel()
        bannerEntry = nil
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { "[\(formatter.string(from: $0.date))] \($0.level.rawValue) · \($0.source): \($0.message)" }
            .joined(separator: "\n")
    }
}
