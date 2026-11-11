import Foundation
import TerminalCore
import XCTest

final class ExecutionTargetTests: XCTestCase {
    func testLabelsMatchInterfaceVocabulary() {
        let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "Build Mac", hostname: "mac.local", username: "ana")
        XCTAssertEqual(ExecutionTarget.local(.vanilla).label, "Local Vanilla")
        XCTAssertEqual(ExecutionTarget.local(.unleashed).label, "Local Unleashed")
        XCTAssertEqual(ExecutionTarget.remote(endpoint).label, "Remote Host")
        XCTAssertEqual(ExecutionTarget.remote(endpoint).detail, "ana@mac.local")
        XCTAssertEqual(ExecutionMode.vanilla.displayName, "Vanilla")
        XCTAssertEqual(ExecutionMode.unleashed.displayName, "Unleashed")
    }

    func testEndpointAddressIncludesNonStandardPort() {
        let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "x", hostname: "h", port: 2222, username: "u")
        XCTAssertEqual(endpoint.address, "u@h:2222")
    }
}

final class ModeSwitchPolicyTests: XCTestCase {
    private let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "Mac", hostname: "mac", username: "me")

    private func snapshot(_ target: ExecutionTarget, _ state: SessionState = .ready, _ title: String = "s") -> SessionSnapshot {
        SessionSnapshot(id: SessionID(), title: title, target: target, state: state)
    }

    func testRemoteSessionsArePreservedAndNeverActedOn() {
        let remote = snapshot(.remote(endpoint), .running(command: "swift build"))
        let plan = ModeSwitchPolicy.plan(from: .vanilla, to: .unleashed, targetModeAvailable: true, sessions: [remote])
        XCTAssertEqual(plan.preservedRemoteSessions, [remote])
        XCTAssertTrue(plan.localSessions.isEmpty)
        XCTAssertFalse(plan.offersMoveConfirmation)
        // Even a decision that names the remote session produces no action for it.
        XCTAssertEqual(ModeSwitchPolicy.actions(for: plan, decision: .moveConfirmed([remote.id])), [])
    }

    func testIdleLocalSessionRequiresExplicitConfirmationToMove() {
        let local = snapshot(.local(.vanilla))
        let plan = ModeSwitchPolicy.plan(from: .vanilla, to: .unleashed, targetModeAvailable: true, sessions: [local])
        XCTAssertTrue(plan.offersMoveConfirmation)
        XCTAssertEqual(plan.sessionsAffectedByMove, [local])
        // Default decision keeps the session where it is.
        XCTAssertEqual(ModeSwitchPolicy.actions(for: plan, decision: .keepCurrentEnvironment), [])
        XCTAssertEqual(
            ModeSwitchPolicy.actions(for: plan, decision: .moveConfirmed([local.id])),
            [.restartLocalSession(local.id, in: .unleashed)]
        )
    }

    func testRunningLocalCommandIsNeverTransferred() {
        let busy = snapshot(.local(.vanilla), .running(command: "find /"))
        let plan = ModeSwitchPolicy.plan(from: .vanilla, to: .unleashed, targetModeAvailable: true, sessions: [busy])
        XCTAssertFalse(plan.offersMoveConfirmation)
        guard case .mustStay = plan.localSessions[0].disposition else { return XCTFail("running session must stay") }
        XCTAssertEqual(ModeSwitchPolicy.actions(for: plan, decision: .moveConfirmed([busy.id])), [])
    }

    func testNothingMovesIntoUnavailableMode() {
        let local = snapshot(.local(.vanilla))
        let plan = ModeSwitchPolicy.plan(from: .vanilla, to: .unleashed, targetModeAvailable: false, sessions: [local])
        XCTAssertFalse(plan.offersMoveConfirmation)
        XCTAssertEqual(ModeSwitchPolicy.actions(for: plan, decision: .moveConfirmed([local.id])), [])
    }

    func testSessionsAlreadyInTargetModeAreUnaffected() {
        let local = snapshot(.local(.unleashed))
        let plan = ModeSwitchPolicy.plan(from: .vanilla, to: .unleashed, targetModeAvailable: true, sessions: [local])
        XCTAssertEqual(plan.localSessions.first?.disposition, .alreadyInTargetMode)
        XCTAssertFalse(plan.offersMoveConfirmation)
    }

    func testOnlyConfirmedSessionsMove() {
        let a = snapshot(.local(.unleashed), .ready, "a")
        let b = snapshot(.local(.unleashed), .ready, "b")
        let plan = ModeSwitchPolicy.plan(from: .unleashed, to: .vanilla, targetModeAvailable: true, sessions: [a, b])
        XCTAssertEqual(ModeSwitchPolicy.actions(for: plan, decision: .moveConfirmed([b.id])), [.restartLocalSession(b.id, in: .vanilla)])
    }
}

final class ShellQuoteTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(ShellQuote.quote("simple/path-1.txt"), "simple/path-1.txt")
        XCTAssertEqual(ShellQuote.quote("has space"), "'has space'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
        XCTAssertEqual(ShellQuote.quote("$(rm -rf /)"), "'$(rm -rf /)'")
        XCTAssertEqual(ShellQuote.join(["ls", "-la", "My Project"]), "ls -la 'My Project'")
    }
}

final class EventChannelTests: XCTestCase {
    func testWriteConvertsNewlines() async {
        let channel = EventChannel<TerminalEvent>()
        channel.write("a\nb\r\n")
        channel.finish()
        var bytes: [UInt8] = []
        for await event in channel.stream { if case .output(let b) = event { bytes += b } }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "a\r\nb\r\n")
    }
}
