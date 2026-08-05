import SwiftUI

struct DebugLogView: View {
    @ObservedObject var diagnostics: DiagnosticsLog
    @Environment(\.dismiss) private var dismiss

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if diagnostics.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Keine Fehler protokolliert")
                            .font(.headline)
                        Text("Bisher sind keine technischen Fehler aufgetreten.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(diagnostics.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.level.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(color(for: entry.level))
                                Text(entry.source)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.timeFormatter.string(from: entry.date))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Debug-Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schliessen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = diagnostics.exportText
                        } label: {
                            Label("Log kopieren", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            diagnostics.clear()
                        } label: {
                            Label("Log leeren", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func color(for level: DiagnosticEntry.Level) -> Color {
        switch level {
        case .error: return Color(red: 0.95, green: 0.4, blue: 0.4)
        case .warning: return Color(red: 0.95, green: 0.7, blue: 0.29)
        case .info: return Color(red: 0.29, green: 0.95, blue: 0.78)
        }
    }
}
