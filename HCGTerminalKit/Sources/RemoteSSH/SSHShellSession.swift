import Diagnostics
import Foundation
import NIOCore
import NIOSSH
import TerminalCore

/// Events from the PTY channel handler to the session actor, delivered in order.
enum ShellChannelEvent: Sendable {
    case data([UInt8])
    case exit(Int32)
    case rejected(String)
    case closed
}

/// Requests a PTY, then a shell or a command, and forwards channel data.
final class ShellChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String?
    private let size: TerminalSize
    private let events: AsyncStream<ShellChannelEvent>.Continuation
    private var awaitingPTYReply = true

    init(command: String?, size: TerminalSize, events: AsyncStream<ShellChannelEvent>.Continuation) {
        self.command = command
        self.size = size
        self.events = events
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.fireChannelActive()
    }

    private func startProgram(context: ChannelHandlerContext) {
        if let command {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        events.yield(.data(Array(buffer.readableBytesView)))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if awaitingPTYReply {
                awaitingPTYReply = false
                startProgram(context: context)
            }
        case is ChannelFailureEvent:
            events.yield(.rejected(awaitingPTYReply ? "a pseudo-terminal" : (command == nil ? "a shell" : "the command")))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            events.yield(.exit(Int32(truncatingIfNeeded: status.exitStatus)))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            events.yield(.exit(128 + (SSHSignals.number(for: signal.signalName) ?? 0)))
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        events.yield(.closed)
        events.finish()
        context.fireChannelInactive()
    }
}

/// An interactive SSH session with a PTY. Implements the shared `TerminalSession`.
public actor SSHShellSession: TerminalSession {
    public nonisolated let id = SessionID()
    public nonisolated let target: ExecutionTarget
    public nonisolated let backend: SessionBackend
    public nonisolated let createdAt = Date()
    public nonisolated var events: AsyncStream<TerminalEvent> { channel.stream }
    public nonisolated let connection: SSHConnection

    private let channel = EventChannel<TerminalEvent>()
    private let command: String?
    private var child: Channel?
    private var pump: Task<Void, Never>?
    private var exitStatus: Int32?
    private var closed = false

    init(connection: SSHConnection, target: ExecutionTarget, backend: SessionBackend, command: String?) {
        self.connection = connection
        self.target = target
        self.backend = backend
        self.command = command
    }

    public func start(size: TerminalSize) async throws {
        guard child == nil, !closed else { return }
        channel.yield(.stateChanged(.connecting))
        let (stream, continuation) = AsyncStream<ShellChannelEvent>.makeStream()
        let command = self.command
        do {
            child = try await connection.openChildChannel { child in
                try child.pipeline.syncOperations.addHandler(ShellChannelHandler(command: command, size: size, events: continuation))
            }
        } catch {
            continuation.finish()
            channel.yield(.stateChanged(.failed(message: error.localizedDescription)))
            throw error
        }
        channel.yield(.stateChanged(.ready))
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: ShellChannelEvent) {
        switch event {
        case .data(let bytes):
            channel.yield(.output(bytes))
        case .exit(let status):
            exitStatus = status
        case .rejected(let what):
            channel.yield(.notice(TerminalNotice(.error, "The server refused to open \(what).")))
        case .closed:
            guard !closed else { return }
            if let exitStatus {
                channel.write("\r\n\(ANSI.dim)[remote process exited with status \(exitStatus)]\(ANSI.reset)\r\n")
                channel.yield(.stateChanged(.exited(status: exitStatus)))
            } else {
                channel.write("\r\n\(ANSI.dim)[connection closed]\(ANSI.reset)\r\n")
                channel.yield(.stateChanged(.closed))
            }
            child = nil
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let child, !closed else { throw ExecutionError.sessionClosed }
        let data = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))
        try await child.writeAndFlush(data).get()
    }

    public func resize(_ size: TerminalSize) async {
        guard let child else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows, terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        try? await child.triggerUserOutboundEvent(request).get()
    }

    public func interrupt() async {
        try? await send([0x03])
    }

    /// Closes this session's channel only. The SSH connection and other sessions stay open.
    public func close() async {
        guard !closed else { return }
        closed = true
        if let child { try? await child.close().get() }
        child = nil
        pump?.cancel()
        channel.yield(.stateChanged(.closed))
        channel.finish()
    }
}
