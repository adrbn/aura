import SwiftUI

struct DevLogsView: View {
    @State private var logger = AppLogger.shared
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var filterLevel: AppLogger.LogLevel?

    private var filteredEntries: [AppLogger.LogEntry] {
        let entries = logger.entries.reversed()
        guard let level = filterLevel else { return Array(entries) }
        return entries.filter { $0.level == level }
    }

    var body: some View {
        List {
            if filteredEntries.isEmpty {
                Text("No logs yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.level.rawValue)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(levelColor(entry.level))
                            Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .endsAboveBottomChrome()
        .scrollIndicators(.hidden)
        .navigationTitle("dev logs (\(filteredEntries.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Filter section
                    Section("Filter") {
                        Button {
                            filterLevel = nil
                        } label: {
                            Label("All Levels", systemImage: filterLevel == nil ? "checkmark" : "")
                        }
                        ForEach([AppLogger.LogLevel.debug, .info, .warning, .error], id: \.rawValue) { level in
                            Button {
                                filterLevel = filterLevel == level ? nil : level
                            } label: {
                                Label(level.rawValue, systemImage: filterLevel == level ? "checkmark" : "")
                            }
                        }
                    }
                    Section {
                        Button {
                            let text = logger.exportText()
                            UIPasteboard.general.string = text
                            ToastManager.shared.show("Logs copied", icon: "doc.on.doc")
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button {
                            if let url = logger.exportToFile() {
                                exportURL = url
                                showShareSheet = true
                            }
                        } label: {
                            Label("Export as File", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            logger.clear()
                        } label: {
                            Label("Clear Logs", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func levelColor(_ level: AppLogger.LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

