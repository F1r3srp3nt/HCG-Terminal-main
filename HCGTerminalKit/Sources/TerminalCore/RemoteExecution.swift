import Foundation

/// One event from a non-interactive remote command.
public enum RemoteExecEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exit(status: Int32)
}

/// The collected result of a remote command.
public struct RemoteExecResult: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    public var status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

/// Runs commands on a remote host without a PTY. Implemented by `RemoteSSH.SSHConnection`;
/// developer tools depend only on this protocol, which keeps them independent of the local
/// execution mode and testable without a network.
public protocol RemoteCommandExecuting: Sendable {
    var endpoint: RemoteEndpoint { get }
    /// Streams the output of `command`, executed by the remote user's shell.
    func stream(_ command: String) -> AsyncThrowingStream<RemoteExecEvent, Error>
}

public extension RemoteCommandExecuting {
    /// Runs `command` and collects its output. `limit` bounds memory use for chatty commands.
    func run(_ command: String, limit: Int = 32 * 1024 * 1024) async throws -> RemoteExecResult {
        var out = Data()
        var err = Data()
        var status: Int32 = -1
        for try await event in stream(command) {
            switch event {
            case .stdout(let data): if out.count < limit { out.append(data) }
            case .stderr(let data): if err.count < limit { err.append(data) }
            case .exit(let code): status = code
            }
        }
        return RemoteExecResult(stdout: out, stderr: err, status: status)
    }
}

/// POSIX shell quoting. Every path or argument interpolated into a remote command goes
/// through here.
public enum ShellQuote {
    /// Wraps `value` in single quotes, escaping embedded single quotes.
    public static func quote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ safeCharacters.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    private static let safeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@+,%")
}
