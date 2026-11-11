import Diagnostics
import Foundation
import TerminalCore
import TerminalSecurity
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Best-effort pre-confirmation of privileged command lines typed into a real shell.
///
/// The shell does its own line editing, so this tracks a shadow copy of what was typed since
/// the last Return. It is disabled while a full-screen program uses the alternate screen and
/// after a password prompt (the shadow buffer is then discarded, never logged).
///
/// This is an extra confirmation layer, not the security boundary: the boundary is that HCG
/// Terminal never elevates on its own — elevation happens only through tools the user runs,
/// with whatever credentials those tools demand.
struct CommandGuard {
    private(set) var shadow: [UInt8] = []
    private var alternateScreen = false
    private var awaitingSecret = false
    private var recentOutput: [UInt8] = []
    private var inEscape = false

    /// Observes terminal output to know when guarding must be suspended.
    mutating func observeOutput(_ bytes: [UInt8]) {
        recentOutput.append(contentsOf: bytes)
        if recentOutput.count > 512 { recentOutput.removeFirst(recentOutput.count - 512) }
        let text = String(decoding: recentOutput, as: UTF8.self)
        func lastPosition(_ markers: [String]) -> String.Index? {
            markers.compactMap { text.range(of: $0, options: .backwards)?.lowerBound }.max()
        }
        let enter = lastPosition(["\u{1B}[?1049h", "\u{1B}[?1047h", "\u{1B}[?47h"])
        let exit = lastPosition(["\u{1B}[?1049l", "\u{1B}[?1047l", "\u{1B}[?47l"])
        switch (enter, exit) {
        case let (entered?, exited?): alternateScreen = entered > exited
        case (.some, nil): alternateScreen = true
        case (nil, .some): alternateScreen = false
        case (nil, nil): break
        }
        let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lowered = lastLine.lowercased().trimmingCharacters(in: .whitespaces)
        awaitingSecret = lowered.hasSuffix("password:") || lowered.hasSuffix("passphrase:") || lowered.contains("[sudo] password")
    }

    enum Decision: Equatable {
        case forward
        /// Return was pressed on this line; ask before forwarding the Return.
        case confirm(line: String, reasons: [String])
    }

    /// Feeds typed bytes. Returns `.confirm` only for a Return that ends a privileged line.
    mutating func observeInput(_ bytes: [UInt8]) -> Decision {
        guard !alternateScreen else { shadow.removeAll(); return .forward }
        for byte in bytes {
            if inEscape {
                if (0x40...0x7E).contains(byte) && byte != UInt8(ascii: "[") && byte != UInt8(ascii: "O") { inEscape = false }
                continue
            }
            switch byte {
            case 0x1B:
                inEscape = true
            case 0x0D, 0x0A:
                defer { shadow.removeAll() }
                if awaitingSecret { return .forward }
                let line = String(decoding: shadow, as: UTF8.self)
                let assessment = PrivilegeClassifier.assess(line)
                if assessment.requiresAuthorization { return .confirm(line: line, reasons: assessment.reasons) }
            case 0x7F, 0x08:
                if !shadow.isEmpty { shadow.removeLast() }
            case 0x03, 0x15:
                shadow.removeAll()
            default:
                if byte >= 0x20 || byte == 0x09 { shadow.append(byte) }
            }
        }
        return .forward
    }
}

/// A Local Unleashed session: a real shell on the device, attached to a pseudo-terminal.
public actor LocalProcessSession: TerminalSession {
    public nonisolated let id = SessionID()
    public nonisolated let target: ExecutionTarget = .local(.unleashed)
    public nonisolated let backend: SessionBackend
    public nonisolated let createdAt = Date()
    public nonisolated var events: AsyncStream<TerminalEvent> { channel.stream }

    private let channel = EventChannel<TerminalEvent>()
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: String?
    private let observations: RuntimeObservations
    private let gate: AuthorizationGate
    private var process: PTYProcess?
    private var guardState = CommandGuard()
    private var awaitingAuthorization = false
    private var closed = false
    private var readerTask: Task<Void, Never>?

    private enum ReaderEvent: Sendable {
        case data([UInt8])
        case exit(Int32)
    }

    public init(
        executable: String,
        arguments: [String] = ["-l"],
        environment: [String: String],
        workingDirectory: String?,
        observations: RuntimeObservations,
        gate: AuthorizationGate
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.observations = observations
        self.gate = gate
        self.backend = .localProcess(executable: executable)
    }

    public func start(size: TerminalSize) async throws {
        guard process == nil, !closed else { return }
        channel.yield(.stateChanged(.connecting))
        do {
            let process = try PTYProcess.spawn(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: workingDirectory, size: size
            )
            self.process = process
            await observations.record(executable: executable, outcome: .succeeded(pid: process.pid))
            await DiagnosticLog.shared.record(.info, "unleashed", "Started local shell", metadata: ["executable": executable, "pid": "\(process.pid)"])
            channel.yield(.stateChanged(.ready))
            // A single consumer keeps output chunks in order.
            let (stream, continuation) = AsyncStream<ReaderEvent>.makeStream()
            process.startReading(
                onData: { continuation.yield(.data($0)) },
                onExit: { continuation.yield(.exit($0)); continuation.finish() }
            )
            readerTask = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case .data(let bytes): await self.received(bytes)
                    case .exit(let status): await self.exited(status)
                    }
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            await observations.record(executable: executable, outcome: .failed(message))
            await DiagnosticLog.shared.record(.warning, "unleashed", "Local shell failed to start", metadata: ["executable": executable, "error": message])
            channel.yield(.notice(TerminalNotice(.error, message)))
            channel.yield(.stateChanged(.failed(message: message)))
            throw ExecutionError.launchFailed(message)
        }
    }

    private func received(_ bytes: [UInt8]) {
        guardState.observeOutput(bytes)
        channel.yield(.output(bytes))
    }

    private func exited(_ status: Int32) {
        guard !closed else { return }
        channel.write("\r\n\(ANSI.dim)[process exited with status \(status)]\(ANSI.reset)\r\n")
        channel.yield(.stateChanged(.exited(status: status)))
        process = nil
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let process, !closed else { throw ExecutionError.sessionClosed }
        guard !awaitingAuthorization else { return } // input is held while the user decides
        switch guardState.observeInput(bytes) {
        case .forward:
            try process.write(bytes)
        case .confirm(let line, let reasons):
            // Forward everything typed before the Return, hold the Return itself.
            if let returnIndex = bytes.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }), returnIndex > 0 {
                try process.write(Array(bytes[..<returnIndex]))
            }
            awaitingAuthorization = true
            let granted = await gate.requestAuthorization(AuthorizationRequest(
                title: "Run a privileged command?", commandLine: line, target: target, reasons: reasons
            ))
            awaitingAuthorization = false
            await DiagnosticLog.shared.record(.notice, "authorization", granted ? "Privileged command approved" : "Privileged command declined", metadata: ["target": target.label])
            if granted {
                try process.write([0x0D])
            } else {
                // Erase the pending line without running it and without signalling anything:
                // Ctrl-E moves to the end (readline/zle; inserted literally by a canonical tty),
                // then Ctrl-U kills the whole line in all three cases.
                try process.write([0x05, 0x15])
                channel.yield(.notice(TerminalNotice(.info, "Not run: authorization was declined.")))
            }
        }
    }

    public func resize(_ size: TerminalSize) async {
        process?.resize(size)
    }

    public func interrupt() async {
        guard let process else { return }
        try? process.write([0x03])
        #if canImport(Darwin)
        // Without a controlling terminal (see PTYProcess) the line discipline cannot signal the
        // foreground job, so signal the session's process group directly.
        process.signal(SIGINT)
        #endif
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        process?.terminate()
        process = nil
        channel.yield(.stateChanged(.closed))
        channel.finish()
    }
}
