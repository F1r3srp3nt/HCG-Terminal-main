import Foundation
import TerminalCore

public enum LogLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case debug, info, notice, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

public struct LogEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String
    public var metadata: [String: String]

    public init(id: UUID = UUID(), date: Date = Date(), level: LogLevel, category: String, message: String, metadata: [String: String] = [:]) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    public var line: String {
        let meta = metadata.isEmpty ? "" : " " + metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(ISO8601DateFormatter().string(from: date)) [\(level.label)] \(category): \(message)\(meta)"
    }
}

/// Structured application log. In-memory ring buffer with an optional JSON-lines file sink.
/// Never records secrets: callers pass identifiers, not credentials.
public actor DiagnosticLog {
    public static let shared = DiagnosticLog()

    private var entries: [LogEntry] = []
    private let capacity: Int
    private var fileURL: URL?

    public init(capacity: Int = 2000, fileURL: URL? = nil) {
        self.capacity = capacity
        self.fileURL = fileURL
    }

    public func attachFile(_ url: URL) {
        fileURL = url
    }

    public func record(_ level: LogLevel, _ category: String, _ message: String, metadata: [String: String] = [:]) {
        let entry = LogEntry(level: level, category: category, message: message, metadata: metadata)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if let fileURL, let data = try? JSONEncoder().encode(entry) {
            append(data + Data([0x0A]), to: fileURL)
        }
    }

    public func recent(minimumLevel: LogLevel = .debug, limit: Int = 500) -> [LogEntry] {
        Array(entries.filter { $0.level >= minimumLevel }.suffix(limit))
    }

    public func exportText() -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    public func clear() {
        entries.removeAll()
    }

    private func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
