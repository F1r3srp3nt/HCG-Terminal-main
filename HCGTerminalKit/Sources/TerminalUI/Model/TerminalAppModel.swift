import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import Diagnostics
import Foundation
import Observation
import RemoteSSH
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity

/// A question the interface must answer before work continues. Each one is resolved exactly
/// once by the user; dismissing it counts as "no".
public struct PendingDecision<Request: Sendable>: Identifiable {
    public let id = UUID()
    public let request: Request
    let resolve: (Bool) -> Void
}

public struct HostKeyPrompt: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var key: PresentedHostKey
}

/// The mode-switch confirmation shown when existing local sessions could be moved.
public struct ModeSwitchConfirmation: Identifiable {
    public let id = UUID()
    public let plan: ModeSwitchPlan
}

/// Root state of the app. Owns sessions and coordinates mode changes.
@MainActor
@Observable
public final class TerminalAppModel {
    public let dependencies: AppDependencies

    // MARK: Mode
    public private(set) var preferredMode: ExecutionMode
    public private(set) var reports: [ExecutionMode: CapabilityReport] = [:]
    public private(set) var isDetecting = false
    public var modeSwitchConfirmation: ModeSwitchConfirmation?

    // MARK: Sessions
    public private(set) var sessions: [SessionModel] = []
    public var selectedSessionID: SessionID?

    // MARK: Prompts
    public var authorizationPrompt: PendingDecision<AuthorizationRequest>?
    public var hostKeyPrompt: PendingDecision<HostKeyPrompt>?
    public var errorMessage: String?

    // MARK: Remote
    public private(set) var hosts: [HostProfile] = []
    public private(set) var keys: [SSHKeyRecord] = []
    @ObservationIgnored private var connections: [UUID: SSHConnection] = [:]

    // MARK: Remote development
    public private(set) var builds: BuildCenter!

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.preferredMode = dependencies.preferences.preferredMode
        self.builds = BuildCenter(dependencies: dependencies) { [weak self] hostID in
            guard let self, let host = self.hosts.first(where: { $0.id == hostID }) else {
                throw RemoteSessionError.unknownHost
            }
            return try await self.connection(for: host)
        }
    }

    /// Wires prompts and loads persisted state. Call once from the root view.
    public func bootstrap() async {
        await dependencies.gate.setPresenter { [weak self] request in
            await self?.ask(authorization: request) ?? false
        }
        hosts = await dependencies.hostStore.all()
        keys = dependencies.keyManager.list()
        await builds.reload()
        await refreshCapabilities()
        await DiagnosticLog.shared.record(.info, "app", "Started", metadata: ["build": dependencies.distribution.rawValue, "mode": preferredMode.rawValue])
    }

    // MARK: - Capabilities

    public func refreshCapabilities() async {
        isDetecting = true
        defer { isDetecting = false }
        async let vanilla = dependencies.vanillaCapabilities.detectCapabilities()
        async let unleashed = dependencies.unleashedCapabilities.detectCapabilities()
        let (v, u) = await (vanilla, unleashed)
        reports[.vanilla] = v
        reports[.unleashed] = u
    }

    public func report(for mode: ExecutionMode) -> CapabilityReport? { reports[mode] }

    /// True when the mode's local features can be used. Remote features never depend on this.
    public func isAvailable(_ mode: ExecutionMode) -> Bool {
        mode == .vanilla || (reports[mode]?.localFeaturesAvailable ?? false)
    }

    // MARK: - Mode switching

    /// Changes the preferred local mode. Never touches remote sessions and never moves a local
    /// session by itself; if local sessions could be moved, a confirmation is offered.
    public func selectMode(_ mode: ExecutionMode) {
        guard mode != preferredMode else { return }
        let previous = preferredMode
        preferredMode = mode
        dependencies.preferences.preferredMode = mode
        let plan = ModeSwitchPolicy.plan(
            from: previous, to: mode, targetModeAvailable: isAvailable(mode),
            sessions: sessions.filter(\.isLive).map(\.snapshot)
        )
        if plan.offersMoveConfirmation {
            modeSwitchConfirmation = ModeSwitchConfirmation(plan: plan)
        }
        Task { await DiagnosticLog.shared.record(.info, "mode", "Preferred mode changed", metadata: ["from": previous.rawValue, "to": mode.rawValue, "remoteSessionsPreserved": "\(plan.preservedRemoteSessions.count)"]) }
        if reports[mode] == nil { Task { await refreshCapabilities() } }
    }

    /// Applies the user's answer to a move offer.
    public func resolveModeSwitch(_ decision: LocalSessionMoveDecision) async {
        guard let confirmation = modeSwitchConfirmation else { return }
        modeSwitchConfirmation = nil
        for action in ModeSwitchPolicy.actions(for: confirmation.plan, decision: decision) {
            guard case .restartLocalSession(let id, let mode) = action,
                  let old = sessions.first(where: { $0.id == id }), !old.state.isRunningCommand else { continue }
            await closeSession(id)
            await openLocalSession(mode: mode)
        }
    }

    // MARK: - Local sessions

    /// Opens a local session in `mode` (default: the preferred mode). Never falls back to a
    /// different mode or to a remote host.
    @discardableResult
    public func openLocalSession(mode requested: ExecutionMode? = nil) async -> SessionModel? {
        let mode = requested ?? preferredMode
        let provider: (any LocalExecutionProvider)?
        switch mode {
        case .vanilla: provider = dependencies.vanilla
        case .unleashed: provider = dependencies.unleashed
        }
        guard let provider, isAvailable(mode) else {
            errorMessage = CapabilityReport.unleashedUnavailableMessage
            return nil
        }
        if mode == .unleashed, case .loopbackService? = await provider.availableBackend() {
            errorMessage = "No shell can be started directly. Use “Connect to Local Terminal Service” and sign in with that service's account."
            return nil
        }
        do {
            let session = try await provider.makeSession()
            guard session.target == .local(mode) else {
                await session.close()
                throw ExecutionError.targetMismatch(expected: .local(mode), actual: session.target)
            }
            return await register(session, title: mode == .vanilla ? "Vanilla" : "Unleashed")
        } catch {
            errorMessage = error.localizedDescription
            await refreshCapabilities() // a failed spawn updates the Unleashed report
            return nil
        }
    }

    /// Connects to an existing terminal service on this device (Unleashed). The session's
    /// target is Local Unleashed, because the commands execute on this device.
    @discardableResult
    public func openLoopbackService(port: Int, username: String, password: String) async -> SessionModel? {
        guard dependencies.distribution == .unleashed, isAvailable(.unleashed) else {
            errorMessage = CapabilityReport.unleashedUnavailableMessage
            return nil
        }
        let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "This device", hostname: "127.0.0.1", port: port, username: username)
        do {
            let connection = try await SSHConnection.connect(endpoint: endpoint, authentication: .password(password), hostKeyPolicy: hostKeyPolicy)
            let session = try await connection.openSession(
                size: .standard, target: .local(.unleashed), backend: .loopbackService(host: "127.0.0.1", port: port)
            )
            return await register(session, title: "Unleashed · service")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Remote sessions

    public var hostKeyPolicy: HostKeyPolicy {
        HostKeyPolicy(knownHosts: dependencies.knownHosts) { [weak self] host, port, key in
            await self?.ask(hostKey: HostKeyPrompt(host: host, port: port, key: key)) ?? false
        }
    }

    func authentication(for host: HostProfile) throws -> SSHAuthentication {
        func password() throws -> String {
            guard let data = try dependencies.credentials.load(.hostPassword(host.id)) else {
                throw RemoteSessionError.missingPassword(host.name)
            }
            return String(decoding: data, as: UTF8.self)
        }
        switch host.auth {
        case .password: return .password(try password())
        case .key(let id): return .ed25519(try dependencies.keyManager.privateKey(for: id))
        case .keyThenPassword(let id):
            return .keyThenPassword(rawKey: try dependencies.keyManager.privateKey(for: id).rawRepresentation, password: try password())
        }
    }

    /// Returns the open connection for `host`, connecting if needed.
    public func connection(for host: HostProfile) async throws -> SSHConnection {
        if let existing = connections[host.id], existing.isActive { return existing }
        let connection = try await SSHConnection.connect(endpoint: host.endpoint, authentication: authentication(for: host), hostKeyPolicy: hostKeyPolicy)
        connections[host.id] = connection
        return connection
    }

    @discardableResult
    public func openRemoteShell(_ host: HostProfile) async -> SessionModel? {
        do {
            let session = try await connection(for: host).openSession(size: .standard)
            return await register(session, title: host.name)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Runs Claude Code in `projectPath` on the remote host, in its own PTY session.
    @discardableResult
    public func openClaudeCode(_ host: HostProfile, projectPath: String) async -> SessionModel? {
        do {
            let session = try await connection(for: host).openSession(size: .standard, command: ClaudeCodeLauncher.command(projectPath: projectPath))
            return await register(session, title: "Claude Code · \(host.name)")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Opens a new Local Unleashed session and types `command` into it — used after the user
    /// approved a package action. The command is visible and runs with the device's permissions.
    public func runApprovedCommandInNewUnleashedSession(_ command: String) async {
        guard let model = await openLocalSession(mode: .unleashed) else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        model.send(Array((command + "\r").utf8))
    }

    public func disconnect(_ host: HostProfile) async {
        for session in sessions where session.target.remoteEndpoint?.hostID == host.id {
            await closeSession(session.id)
        }
        await connections.removeValue(forKey: host.id)?.close()
    }

    /// Test hook for registering arbitrary sessions.
    var sessionsForTesting: [SessionModel] {
        get { sessions }
        set { sessions = newValue }
    }

    public func isConnected(_ host: HostProfile) -> Bool { connections[host.id]?.isActive ?? false }

    // MARK: - Session bookkeeping

    private func register(_ session: any TerminalSession, title: String) async -> SessionModel {
        let model = SessionModel(session: session, title: title, modeAtCreation: preferredMode)
        model.attach()
        sessions.append(model)
        selectedSessionID = model.id
        do {
            try await session.start(size: .standard)
        } catch {
            errorMessage = error.localizedDescription
            await refreshCapabilities()
        }
        return model
    }

    public func session(_ id: SessionID?) -> SessionModel? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    public func closeSession(_ id: SessionID) async {
        guard let model = sessions.first(where: { $0.id == id }) else { return }
        await model.close()
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = sessions.last?.id }
    }

    // MARK: - Hosts and keys

    public func saveHost(_ host: HostProfile, password: String?) async {
        do {
            if let password, !password.isEmpty {
                try dependencies.credentials.save(Data(password.utf8), for: .hostPassword(host.id))
            }
            try await dependencies.hostStore.save(host)
            hosts = await dependencies.hostStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteHost(_ host: HostProfile) async {
        await disconnect(host)
        try? dependencies.credentials.delete(.hostPassword(host.id))
        try? await dependencies.hostStore.delete(host.id)
        hosts = await dependencies.hostStore.all()
    }

    @discardableResult
    public func generateKey(comment: String) -> SSHKeyRecord? {
        do {
            let record = try dependencies.keyManager.generateEd25519(comment: comment)
            keys = dependencies.keyManager.list()
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func deleteKey(_ record: SSHKeyRecord) {
        try? dependencies.keyManager.delete(record.id)
        keys = dependencies.keyManager.list()
    }

    // MARK: - Prompts

    func ask(authorization request: AuthorizationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            // A new request while one is open denies the older one; nothing is ever approved implicitly.
            authorizationPrompt?.resolve(false)
            var resolved = false
            authorizationPrompt = PendingDecision(request: request) { [weak self] granted in
                guard !resolved else { return }
                resolved = true
                self?.authorizationPrompt = nil
                continuation.resume(returning: granted)
            }
        }
    }

    func ask(hostKey prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyPrompt?.resolve(false)
            var resolved = false
            hostKeyPrompt = PendingDecision(request: prompt) { [weak self] approved in
                guard !resolved else { return }
                resolved = true
                self?.hostKeyPrompt = nil
                continuation.resume(returning: approved)
            }
        }
    }

    public func answerAuthorization(_ granted: Bool) { authorizationPrompt?.resolve(granted) }
    public func answerHostKey(_ approved: Bool) { hostKeyPrompt?.resolve(approved) }
}

public enum RemoteSessionError: Error, LocalizedError, Equatable {
    case missingPassword(String)
    case unknownHost

    public var errorDescription: String? {
        switch self {
        case .missingPassword(let host): "No password is saved for \(host). Edit the host to add one."
        case .unknownHost: "The host for this build is no longer saved."
        }
    }
}
