import Foundation

/// Stable identifier of a terminal session.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { String(rawValue.uuidString.prefix(8)).lowercased() }
}

/// Size of the terminal grid in character cells.
public struct TerminalSize: Hashable, Codable, Sendable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
    public static let standard = TerminalSize(columns: 80, rows: 24)
}

/// Lifecycle of a session.
public enum SessionState: Hashable, Sendable {
    case notStarted
    case connecting
    case ready
    /// A command is currently executing in the session (local sessions only report this).
    case running(command: String)
    case exited(status: Int32)
    case failed(message: String)
    case closed

    public var isTerminal: Bool {
        switch self {
        case .exited, .failed, .closed: true
        default: false
        }
    }

    public var isRunningCommand: Bool {
        if case .running = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .notStarted: "Not started"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .running(let command): "Running \(command)"
        case .exited(let status): "Exited (\(status))"
        case .failed(let message): "Failed: \(message)"
        case .closed: "Closed"
        }
    }
}

/// How the session's backend is implemented. Shown in session details so the user always
/// knows what is actually executing their input.
public enum SessionBackend: Hashable, Codable, Sendable {
    /// HCG Terminal's own built-in commands operating on the app sandbox.
    case builtInCommands
    /// A local executable spawned on the device (for example `/var/jb/bin/sh`).
    case localProcess(executable: String)
    /// An existing terminal service on this device reached over the loopback interface.
    case loopbackService(host: String, port: Int)
    /// An interactive SSH shell with a pseudo-terminal.
    case sshShell
    /// A single SSH command with a pseudo-terminal (for example Claude Code).
    case sshCommand(String)

    public var label: String {
        switch self {
        case .builtInCommands: "Built-in commands (app sandbox)"
        case .localProcess(let executable): "Local process · \(executable)"
        case .loopbackService(let host, let port): "Local terminal service · \(host):\(port)"
        case .sshShell: "SSH interactive shell (PTY)"
        case .sshCommand(let command): "SSH command (PTY) · \(command)"
        }
    }
}

/// A non-terminal message the session wants the interface to show (outside the byte stream).
public struct TerminalNotice: Hashable, Sendable {
    public enum Kind: String, Sendable { case info, warning, error }
    public var kind: Kind
    public var message: String
    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Everything a session emits.
public enum TerminalEvent: Sendable {
    /// Bytes for the terminal emulator (UTF-8, may contain ANSI escape sequences).
    case output([UInt8])
    case stateChanged(SessionState)
    case notice(TerminalNotice)
    case title(String)
    case workingDirectory(String)
}

/// Shared abstraction implemented by every session type: local Vanilla built-ins,
/// local Unleashed processes, loopback services and remote SSH shells.
///
/// Input is always raw terminal bytes (what the keyboard produced). Each implementation is
/// responsible for its own line discipline or forwards bytes to a real PTY.
public protocol TerminalSession: AnyObject, Sendable {
    var id: SessionID { get }
    var target: ExecutionTarget { get }
    var backend: SessionBackend { get }
    var createdAt: Date { get }
    /// Single-consumer stream of events. The interface subscribes once.
    var events: AsyncStream<TerminalEvent> { get }

    func start(size: TerminalSize) async throws
    func send(_ bytes: [UInt8]) async throws
    func resize(_ size: TerminalSize) async
    /// Ctrl-C semantics: interrupt the foreground command, never the session itself.
    func interrupt() async
    func close() async
}

public extension TerminalSession {
    func send(text: String) async throws {
        try await send(Array(text.utf8))
    }
}

/// Factory for local sessions. Implemented separately by the Vanilla and Unleashed providers.
public protocol LocalExecutionProvider: Sendable {
    var mode: ExecutionMode { get }
    /// Human-readable description of the backend a new session would use, or `nil` when no
    /// session can be created in the current environment.
    func availableBackend() async -> SessionBackend?
    func makeSession() async throws -> any TerminalSession
}

/// Errors shared across execution providers.
public enum ExecutionError: Error, LocalizedError, Equatable, Sendable {
    case modeUnavailable(ExecutionMode, reason: String)
    case sessionClosed
    case notAuthorized(String)
    case targetMismatch(expected: ExecutionTarget, actual: ExecutionTarget)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modeUnavailable(let mode, let reason): "\(mode.displayName) is not available: \(reason)"
        case .sessionClosed: "The session is closed."
        case .notAuthorized(let what): "Not authorized: \(what)"
        case .targetMismatch(let expected, let actual):
            "Refused to run a command for \(expected.label) on \(actual.label)."
        case .launchFailed(let reason): "Could not start: \(reason)"
        }
    }
}
