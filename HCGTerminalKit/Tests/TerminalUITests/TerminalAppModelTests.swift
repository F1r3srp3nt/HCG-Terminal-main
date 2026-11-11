import FileWorkspace
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
@testable import TerminalUI
import XCTest

/// A remote-looking session that records what is done to it.
actor FakeRemoteSession: TerminalSession {
    nonisolated let id = SessionID()
    nonisolated let target: ExecutionTarget
    nonisolated let backend: SessionBackend = .sshShell
    nonisolated let createdAt = Date()
    nonisolated var events: AsyncStream<TerminalEvent> { channel.stream }
    private let channel = EventChannel<TerminalEvent>()
    private(set) var closeCount = 0
    private(set) var interruptCount = 0
    private(set) var received: [[UInt8]] = []

    init(endpoint: RemoteEndpoint) { target = .remote(endpoint) }

    func start(size: TerminalSize) async throws { channel.yield(.stateChanged(.ready)) }
    func send(_ bytes: [UInt8]) async throws { received.append(bytes) }
    func resize(_ size: TerminalSize) async {}
    func interrupt() async { interruptCount += 1 }
    func close() async { closeCount += 1; channel.finish() }
}

@MainActor
final class TerminalAppModelTests: XCTestCase {
    var root: URL!
    var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-app-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "hcg-test-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func makeModel() throws -> TerminalAppModel {
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        let deps = AppDependencies.standard(
            workspace: workspace, supportDirectory: root.appendingPathComponent("support"),
            credentials: InMemoryCredentialStore(), preferences: ModePreferenceStore(defaults: defaults)
        )
        return TerminalAppModel(dependencies: deps)
    }

    func testStandardBuildReportsUnleashedUnavailableAndDoesNotCrash() async throws {
        let model = try makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.preferredMode, .vanilla)
        model.selectMode(.unleashed)
        XCTAssertEqual(model.preferredMode, .unleashed)
        XCTAssertFalse(model.isAvailable(.unleashed))
        XCTAssertEqual(model.report(for: .unleashed)?.headline, CapabilityReport.unleashedUnavailableMessage)
        let session = await model.openLocalSession()
        XCTAssertNil(session)
        XCTAssertEqual(model.errorMessage, CapabilityReport.unleashedUnavailableMessage)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testPreferenceIsPersisted() async throws {
        let first = try makeModel()
        first.selectMode(.unleashed)
        let second = try makeModel()
        XCTAssertEqual(second.preferredMode, .unleashed)
    }

    func testSwitchingModesPreservesRemoteSessions() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let fake = FakeRemoteSession(endpoint: RemoteEndpoint(hostID: UUID(), displayName: "Mac", hostname: "mac", username: "me"))
        let remote = await model.registerForTesting(fake)
        let local = await model.openLocalSession(mode: .vanilla)
        XCTAssertNotNil(local)

        model.selectMode(.unleashed)
        model.selectMode(.vanilla)
        model.selectMode(.unleashed)
        // Unleashed is unavailable here, so nothing can be moved and no confirmation is offered.
        XCTAssertNil(model.modeSwitchConfirmation)
        await model.resolveModeSwitch(.moveConfirmed(Set(model.sessions.map(\.id))))

        let closes = await fake.closeCount
        XCTAssertEqual(closes, 0)
        XCTAssertTrue(model.sessions.contains { $0.id == remote.id })
        XCTAssertEqual(remote.target.label, "Remote Host")
        XCTAssertEqual(local?.target, .local(.vanilla), "existing local session keeps its execution context")
    }

    func testLocalMoveNeedsConfirmationAndRestartsFresh() async throws {
        struct AvailableUnleashed: TerminalCapabilityProvider {
            let mode: ExecutionMode = .unleashed
            func detectCapabilities() async -> CapabilityReport {
                CapabilityReport(mode: .unleashed, results: [CapabilityResult(kind: .localShell, availability: .available, summary: "test")], localFeaturesAvailable: true, headline: "ok")
            }
        }
        struct FakeUnleashedProvider: LocalExecutionProvider {
            let mode: ExecutionMode = .unleashed
            let workspace: FileWorkspace
            func availableBackend() async -> SessionBackend? { .localProcess(executable: "/fake/sh") }
            func makeSession() async throws -> any TerminalSession {
                BuiltinShellSessionFactory.make(target: .local(.unleashed), workspace: workspace)
            }
        }
        var model = try makeModel()
        var deps = model.dependencies
        deps.unleashedCapabilities = AvailableUnleashed()
        deps.unleashed = FakeUnleashedProvider(workspace: deps.workspace)
        model = TerminalAppModel(dependencies: deps)
        await model.bootstrap()
        XCTAssertTrue(model.isAvailable(.unleashed))

        let fake = FakeRemoteSession(endpoint: RemoteEndpoint(hostID: UUID(), displayName: "Mac", hostname: "mac", username: "me"))
        let remote = await model.registerForTesting(fake)
        let vanilla_opt = await model.openLocalSession(mode: .vanilla)
        let vanilla = try XCTUnwrap(vanilla_opt)

        model.selectMode(.unleashed)
        let confirmation = try XCTUnwrap(model.modeSwitchConfirmation, "an idle local session can be moved, so the user is asked")
        XCTAssertEqual(confirmation.plan.sessionsAffectedByMove.map(\.id), [vanilla.id])
        XCTAssertEqual(confirmation.plan.preservedRemoteSessions.map(\.id), [remote.id])

        // Default answer: keep. Nothing changes.
        await model.resolveModeSwitch(.keepCurrentEnvironment)
        XCTAssertTrue(model.sessions.contains { $0.id == vanilla.id })

        // Ask again and confirm: the Vanilla session is closed and a fresh Unleashed one opens.
        model.selectMode(.vanilla)
        model.selectMode(.unleashed)
        await model.resolveModeSwitch(.moveConfirmed([vanilla.id, remote.id]))
        XCTAssertFalse(model.sessions.contains { $0.id == vanilla.id })
        XCTAssertTrue(model.sessions.contains { $0.target == .local(.unleashed) })
        XCTAssertTrue(model.sessions.contains { $0.id == remote.id })
        let closes = await fake.closeCount
        XCTAssertEqual(closes, 0, "remote sessions are never closed by a mode switch")
    }

    func testOnlyExplicitApprovalAuthorizes() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let request = AuthorizationRequest(title: "t", commandLine: "sudo x", target: .local(.unleashed), reasons: ["r"])
        async let decision = model.dependencies.gate.requestAuthorization(request)
        while model.authorizationPrompt == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.authorizationPrompt?.request.commandLine, "sudo x")
        model.answerAuthorization(false)
        let granted = await decision
        XCTAssertFalse(granted)
        XCTAssertNil(model.authorizationPrompt)
    }

    func testVanillaSessionRunsBuiltInsLocally() async throws {
        let model = try makeModel()
        await model.bootstrap()
        let session_opt = await model.openLocalSession()
        let session = try XCTUnwrap(session_opt)
        XCTAssertEqual(session.target, .local(.vanilla))
        XCTAssertEqual(session.backend, .builtInCommands)
        session.send(Array("echo model-$((1))\r".utf8))
        for _ in 0..<200 where !String(decoding: session.replay, as: UTF8.self).contains("model-") {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(String(decoding: session.replay, as: UTF8.self).contains("model-"))
        await model.closeSession(session.id)
        XCTAssertTrue(model.sessions.isEmpty)
    }
}

import LocalCommandEngine

enum BuiltinShellSessionFactory {
    static func make(target: ExecutionTarget, workspace: FileWorkspace) -> BuiltinShellSession {
        BuiltinShellSession(
            configuration: BuiltinShellConfiguration(
                target: target, workspace: workspace, environment: [:], banner: "", promptLabel: "t", promptColor: "",
                sessionDescription: [], capabilityDescription: { "" }
            ),
            external: RefusingExternalCommandHandler(policyDescription: "", explanation: "")
        )
    }
}

extension TerminalAppModel {
    func registerForTesting(_ session: any TerminalSession) async -> SessionModel {
        let model = SessionModel(session: session, title: "test", modeAtCreation: preferredMode)
        model.attach()
        try? await session.start(size: .standard)
        sessionsForTesting.append(model)
        return model
    }
}
