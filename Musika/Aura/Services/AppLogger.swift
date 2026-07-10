import Foundation

@Observable
final class AppLogger {
    static let shared = AppLogger()
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
    }

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 2000

    func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        let timestamp = Self.timestampFormatter.string(from: entry.timestamp)
        print("[Aura] \(timestamp) [\(level.rawValue)] \(message)")
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func debug(_ message: String) { log(message, level: .debug) }
    func warn(_ message: String) { log(message, level: .warning) }
    func error(_ message: String) { log(message, level: .error) }

    func clear() {
        entries.removeAll()
    }

    /// Export all logs as a formatted string
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Write logs to a temporary file and return its URL for sharing
    func exportToFile() -> URL? {
        let text = exportText()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = "aura_logs_\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
