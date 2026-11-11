import Foundation
import Observation
import TerminalCore

/// Observable wrapper around one `TerminalSession` for the interface.
@MainActor
@Observable
public final class SessionModel: Identifiable {
    public let id: SessionID
    public let session: any TerminalSession
    public let target: ExecutionTarget
    public let backend: SessionBackend
    public let createdAt: Date
    /// The preferred local mode at the moment the session was opened (for session details).
    public let modeAtCreation: ExecutionMode
    public var title: String
    public private(set) var state: SessionState = .notStarted
    public private(set) var notices: [TerminalNotice] = []
    public private(set) var workingDirectory: String?
    public private(set) var lastActivity: Date

    /// Replay buffer so a re-created terminal view shows the scrollback.
    @ObservationIgnored private var buffer: [UInt8] = []
    @ObservationIgnored private let bufferLimit = 2 * 1024 * 1024
    /// Live output consumer (the terminal view). Set and cleared by the view.
    @ObservationIgnored public var outputSink: (([UInt8]) -> Void)?
    @ObservationIgnored private var pump: Task<Void, Never>?

    public init(session: any TerminalSession, title: String, modeAtCreation: ExecutionMode) {
        self.id = session.id
        self.session = session
        self.target = session.target
        self.backend = session.backend
        self.createdAt = session.createdAt
        self.modeAtCreation = modeAtCreation
        self.title = title
        self.lastActivity = session.createdAt
    }

    /// Starts consuming events. Call once.
    public func attach() {
        guard pump == nil else { return }
        let events = session.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func handle(_ event: TerminalEvent) {
        switch event {
        case .output(let bytes):
            buffer.append(contentsOf: bytes)
            if buffer.count > bufferLimit { buffer.removeFirst(buffer.count - bufferLimit) }
            lastActivity = Date()
            outputSink?(bytes)
        case .stateChanged(let newState):
            state = newState
        case .notice(let notice):
            notices.append(notice)
            if notices.count > 20 { notices.removeFirst() }
        case .title(let newTitle):
            if !newTitle.isEmpty { title = newTitle }
        case .workingDirectory(let directory):
            workingDirectory = directory
        }
    }

    public var replay: [UInt8] { buffer }

    public func dismissNotice(_ notice: TerminalNotice) {
        notices.removeAll { $0 == notice }
    }

    public var snapshot: SessionSnapshot {
        SessionSnapshot(id: id, title: title, target: target, state: state)
    }

    public var isLive: Bool { !state.isTerminal }

    // Input from the terminal view.
    public func send(_ bytes: [UInt8]) {
        let session = self.session
        Task {
            do { try await session.send(bytes) } catch {
                self.handle(.notice(TerminalNotice(.warning, "Input not delivered: \(error.localizedDescription)")))
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        let session = self.session
        Task { await session.resize(TerminalSize(columns: columns, rows: rows)) }
    }

    public func interrupt() {
        let session = self.session
        Task { await session.interrupt() }
    }

    public func close() async {
        await session.close()
        pump?.cancel()
        outputSink = nil
    }
}
