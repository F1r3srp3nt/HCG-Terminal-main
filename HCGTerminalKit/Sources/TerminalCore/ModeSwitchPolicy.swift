import Foundation

/// What the mode-switch policy needs to know about one open session.
public struct SessionSnapshot: Hashable, Sendable {
    public var id: SessionID
    public var title: String
    public var target: ExecutionTarget
    public var state: SessionState

    public init(id: SessionID, title: String, target: ExecutionTarget, state: SessionState) {
        self.id = id
        self.title = title
        self.target = target
        self.state = state
    }
}

/// The result of planning a switch of the preferred local mode.
///
/// Rules (see docs/ARCHITECTURE.md, "Session safety"):
/// - Remote sessions are never touched. Their target does not depend on the local mode.
/// - Local sessions keep their current execution environment by default. Changing the mode
///   only changes where *new* local sessions run.
/// - Moving an existing local session to the new environment is a separate, explicit,
///   confirmed action. It closes the old session and opens a fresh one; no command, input or
///   process is transferred.
/// - A local session that is running a command cannot be moved.
/// - Nothing can be moved into a mode whose capabilities are unavailable.
public struct ModeSwitchPlan: Hashable, Sendable {
    public enum LocalDisposition: Hashable, Sendable {
        /// Already in the requested mode. Nothing to do.
        case alreadyInTargetMode
        /// Can be moved to the new mode if the user explicitly confirms.
        case movableWithConfirmation
        /// Must stay where it is (reason shown to the user).
        case mustStay(reason: String)
    }

    public struct LocalEntry: Hashable, Sendable {
        public var session: SessionSnapshot
        public var disposition: LocalDisposition
    }

    public var from: ExecutionMode
    public var to: ExecutionMode
    public var targetModeAvailable: Bool
    /// Remote sessions, preserved untouched.
    public var preservedRemoteSessions: [SessionSnapshot]
    public var localSessions: [LocalEntry]

    /// Local sessions whose execution environment would change if moved.
    public var sessionsAffectedByMove: [SessionSnapshot] {
        localSessions.compactMap { entry in
            if case .movableWithConfirmation = entry.disposition { return entry.session }
            return nil
        }
    }

    /// True when the switch should present a confirmation offering to move local sessions.
    /// Switching the preference itself never needs confirmation, because it never changes the
    /// execution context of an existing session.
    public var offersMoveConfirmation: Bool { !sessionsAffectedByMove.isEmpty }

    public var isNoOp: Bool { from == to }
}

/// The user's answer to a move offer.
public enum LocalSessionMoveDecision: Hashable, Sendable {
    /// Default. Existing local sessions stay in their current environment.
    case keepCurrentEnvironment
    /// The user explicitly confirmed moving these sessions (restart in the new environment).
    case moveConfirmed(Set<SessionID>)
}

/// One concrete action derived from a plan and a decision.
public enum ModeSwitchAction: Hashable, Sendable {
    /// Close the session and open a fresh one in `mode`. Nothing is carried over.
    case restartLocalSession(SessionID, in: ExecutionMode)
}

public enum ModeSwitchPolicy {
    public static func plan(
        from: ExecutionMode,
        to: ExecutionMode,
        targetModeAvailable: Bool,
        sessions: [SessionSnapshot]
    ) -> ModeSwitchPlan {
        var remote: [SessionSnapshot] = []
        var local: [ModeSwitchPlan.LocalEntry] = []
        for session in sessions {
            switch session.target {
            case .remote:
                remote.append(session)
            case .local(let mode):
                let disposition: ModeSwitchPlan.LocalDisposition
                if mode == to {
                    disposition = .alreadyInTargetMode
                } else if session.state.isTerminal {
                    disposition = .mustStay(reason: "The session has ended.")
                } else if session.state.isRunningCommand {
                    disposition = .mustStay(reason: "A command is running. Finish or interrupt it first; running commands are never transferred.")
                } else if !targetModeAvailable {
                    disposition = .mustStay(reason: "\(to.displayName) is not available in this environment.")
                } else {
                    disposition = .movableWithConfirmation
                }
                local.append(.init(session: session, disposition: disposition))
            }
        }
        return ModeSwitchPlan(
            from: from, to: to, targetModeAvailable: targetModeAvailable,
            preservedRemoteSessions: remote, localSessions: local
        )
    }

    /// Turns the plan plus the user's decision into actions. Only sessions that the plan marked
    /// movable *and* the user explicitly confirmed are acted on; remote sessions never appear.
    public static func actions(for plan: ModeSwitchPlan, decision: LocalSessionMoveDecision) -> [ModeSwitchAction] {
        guard case .moveConfirmed(let confirmed) = decision, plan.targetModeAvailable else { return [] }
        return plan.sessionsAffectedByMove
            .filter { confirmed.contains($0.id) }
            .map { .restartLocalSession($0.id, in: plan.to) }
    }
}
