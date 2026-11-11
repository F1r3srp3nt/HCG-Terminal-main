import FileWorkspace
import Foundation
import LocalCommandEngine
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
@testable import UnleashedExecutionProvider
import VanillaExecutionProvider
import XCTest

/// A scripted, read-only environment.
struct ScriptedProbe: SystemProbing {
    var directories: Set<String> = []
    var executables: Set<String> = []
    var readable: Set<String> = []
    var writable: Set<String> = []
    var listings: [String: [String]] = [:]
    var euid: UInt32 = 501
    var ports: Set<Int> = []
    var processCount: Int? = 1

    func exists(_ path: String) -> Bool { directories.contains(path) || executables.contains(path) || readable.contains(path) }
    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func isReadable(_ path: String) -> Bool { readable.contains(path) }
    func isWritable(_ path: String) -> Bool { writable.contains(path) }
    func isExecutableFile(_ path: String) -> Bool { executables.contains(path) }
    func listDirectory(_ path: String) -> [String]? { listings[path] }
    func effectiveUserID() -> UInt32 { euid }
    func loopbackPortAccepts(_ port: Int, timeout: TimeInterval) -> Bool { ports.contains(port) }
    func visibleProcessCount() -> Int? { processCount }
    func osDescription() -> String { "Scripted" }

    static let stockDevice = ScriptedProbe()

    static let rootlessDevice = ScriptedProbe(
        directories: ["/var/jb", "/var/mobile"],
        executables: ["/var/jb/bin/sh", "/var/jb/usr/bin/bash", "/var/jb/usr/bin/apt", "/var/jb/usr/bin/dpkg-query", "/var/jb/usr/bin/sudo", "/var/jb/usr/bin/ls"],
        readable: ["/var/jb", "/var/mobile"],
        listings: ["/var/jb/usr/bin": ["bash", "apt", "dpkg-query", "sudo", "ls"], "/var/jb": ["usr", "bin"], "/var/mobile": ["Documents"]],
        processCount: 212
    )
}

final class UnleashedDetectionTests: XCTestCase {
    func testStandardDeviceReportsUnavailableTruthfully() async throws {
        let provider = UnleashedCapabilityProvider(probe: ScriptedProbe.stockDevice, observations: RuntimeObservations())
        let report = await provider.detectCapabilities()
        XCTAssertFalse(report.localFeaturesAvailable)
        XCTAssertEqual(report.headline, "Unleashed features are not available in this environment. Vanilla terminal and remote development remain available.")
        for kind in [CapabilityKind.localShell, .executableAccess, .filesystemPermissions, .packageManager, .processInspection, .privilegedOperations] {
            XCTAssertFalse(report[kind].availability.isUsable, kind.rawValue)
        }
        XCTAssertEqual(report[.remoteSSH].availability, .available)
        XCTAssertTrue(report[.buildOrchestration].availability.isUsable)
    }

    func testSelectingUnleashedOnStandardDeviceDoesNotCrash() async {
        let observations = RuntimeObservations()
        let provider = UnleashedExecutionProvider(
            capabilities: UnleashedCapabilityProvider(probe: ScriptedProbe.stockDevice, observations: observations),
            observations: observations, gate: AuthorizationGate()
        )
        let backend = await provider.availableBackend()
        XCTAssertNil(backend)
        do {
            _ = try await provider.makeSession()
            XCTFail("must not create a session")
        } catch let error as ExecutionError {
            guard case .modeUnavailable(.unleashed, _) = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testSingleIndicatorIsNotEnough() async {
        // A /var/jb directory alone (no shell, no service) does not make Unleashed available.
        let probe = ScriptedProbe(directories: ["/var/jb"], readable: ["/var/jb"])
        let report = await UnleashedCapabilityProvider(probe: probe, observations: RuntimeObservations()).detectCapabilities()
        XCTAssertFalse(report.localFeaturesAvailable)
        XCTAssertFalse(report[.localShell].availability.isUsable)
    }

    func testDetectedCapabilitiesAreNotClaimedAsVerified() async {
        let report = await UnleashedCapabilityProvider(probe: ScriptedProbe.rootlessDevice, observations: RuntimeObservations()).detectCapabilities()
        XCTAssertTrue(report.localFeaturesAvailable)
        guard case .unverified = report[.localShell].availability else { return XCTFail("\(report[.localShell].availability)") }
        guard case .unverified = report[.executableAccess].availability else { return XCTFail() }
        guard case .requiresAuthorization = report[.packageManager].availability else { return XCTFail() }
        guard case .requiresAuthorization = report[.privilegedOperations].availability else { return XCTFail() }
        XCTAssertEqual(report[.processInspection].availability, .available)
        XCTAssertFalse(report[.localShell].evidence.isEmpty)
    }

    func testLoopbackServiceIsReportedWithoutShell() async {
        let probe = ScriptedProbe(ports: [22])
        let report = await UnleashedCapabilityProvider(probe: probe, observations: RuntimeObservations()).detectCapabilities()
        XCTAssertTrue(report.localFeaturesAvailable)
        guard case .limited(let detail) = report[.localShell].availability else { return XCTFail() }
        XCTAssertTrue(detail.contains("127.0.0.1:22"))
    }

    func testSpawnFailureIsReportedWithRealError() async throws {
        let observations = RuntimeObservations()
        let session = LocalProcessSession(executable: "/nonexistent/hcg-sh", environment: [:], workingDirectory: nil, observations: observations, gate: AuthorizationGate())
        do {
            try await session.start(size: .standard)
            XCTFail("spawn must fail")
        } catch {}
        var scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice).scan()
        scan.shells = ["/nonexistent/hcg-sh"]
        let report = await UnleashedCapabilityProvider.report(for: scan, observations: observations)
        guard case .unavailable(let detail) = report[.localShell].availability else { return XCTFail() }
        XCTAssertTrue(detail.contains("No such file or directory"), detail)
        XCTAssertFalse(report.localFeaturesAvailable)
    }
}

/// These run real processes on the machine executing the tests (Linux CI, or a Mac).
final class UnleashedRealExecutionTests: XCTestCase {
    private func collect(_ session: LocalProcessSession, until predicate: @escaping @Sendable (String) -> Bool) -> Task<String, Never> {
        Task {
            var text = ""
            for await event in session.events {
                if case .output(let bytes) = event { text += String(decoding: bytes, as: UTF8.self) }
                if case .stateChanged(let state) = event, state.isTerminal { break }
                if predicate(text) { break }
            }
            return text
        }
    }

    func testLiveScanFindsShellOnThisHost() throws {
        let scan = UnleashedEnvironmentScanner(probe: LiveSystemProbe()).scan()
        try XCTSkipIf(scan.shells.isEmpty, "no shell visible on this host")
        XCTAssertTrue(scan.shells.contains { $0.hasSuffix("/sh") || $0.hasSuffix("bash") || $0.hasSuffix("zsh") })
    }

    func testPTYSessionExecutesRealCommandsAndIsVerified() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        let observations = RuntimeObservations()
        let session = LocalProcessSession(executable: "/bin/sh", arguments: [], environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "], workingDirectory: "/", observations: observations, gate: AuthorizationGate())
        let output = collect(session) { $0.contains("RESULT-42") }
        try await session.start(size: TerminalSize(columns: 100, rows: 30))
        try await session.send(text: "echo RESULT-$((6*7)); stty size\r")
        let text = await output.value
        XCTAssertTrue(text.contains("RESULT-42"), text)
        guard case .succeeded? = await observations.outcome(for: "/bin/sh") else { return XCTFail() }

        var scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice).scan()
        scan.shells = ["/bin/sh"]
        let report = await UnleashedCapabilityProvider.report(for: scan, observations: observations)
        XCTAssertEqual(report[.localShell].availability, .available)
        await session.close()
    }

    func testWindowSizeIsAppliedToPTY() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        let session = LocalProcessSession(executable: "/bin/sh", arguments: [], environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "], workingDirectory: "/", observations: RuntimeObservations(), gate: AuthorizationGate())
        let output = collect(session) { $0.contains("SIZE=33 101") }
        try await session.start(size: TerminalSize(columns: 101, rows: 33))
        try await session.send(text: "echo SIZE=$(stty size)\r")
        let text = await output.value
        XCTAssertTrue(text.contains("SIZE=33 101"), text)
        await session.close()
    }

    func testExitStatusIsReported() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        let session = LocalProcessSession(executable: "/bin/sh", arguments: [], environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "], workingDirectory: "/", observations: RuntimeObservations(), gate: AuthorizationGate())
        let states = Task { () -> SessionState? in
            for await event in session.events { if case .stateChanged(let s) = event, case .exited = s { return s } }
            return nil
        }
        try await session.start(size: .standard)
        try await session.send(text: "exit 7\r")
        let state = await states.value
        XCTAssertEqual(state, .exited(status: 7))
    }

    func testPrivilegedLineIsHeldUntilAuthorizedAndDeclinedLineNeverRuns() async throws {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(shells.isEmpty)
        for shell in shells { try await guardScenario(shell: shell) }
    }

    private func guardScenario(shell: String) async throws {
        final class Decisions: @unchecked Sendable {
            var requests: [AuthorizationRequest] = []
            var answer = false
        }
        let decisions = Decisions()
        let gate = AuthorizationGate(presenter: { request in
            decisions.requests.append(request)
            return decisions.answer
        })
        let arguments = shell.hasSuffix("bash") ? ["--norc", "--noprofile", "-i"] : shell.hasSuffix("zsh") ? ["-f", "-i"] : []
        let session = LocalProcessSession(executable: shell, arguments: arguments, environment: ["PATH": "/usr/bin:/bin", "PS1": "$ ", "TERM": "xterm-256color"], workingDirectory: "/", observations: RuntimeObservations(), gate: gate)
        let output = collect(session) { $0.contains("AFTER-2") }
        try await session.start(size: .standard)
        try await Task.sleep(nanoseconds: 200_000_000)

        // `killall -0` is classified as privileged. Declined: the marker must never be computed.
        decisions.answer = false
        try await session.send(text: "killall -0 hcg-none 2>/dev/null; echo DENIED-$((40+2))\r")
        try await Task.sleep(nanoseconds: 300_000_000)
        // Approved: runs exactly as typed.
        decisions.answer = true
        try await session.send(text: "killall -0 hcg-none 2>/dev/null; echo ALLOWED-$((40+2))\r")
        try await Task.sleep(nanoseconds: 300_000_000)
        try await session.send(text: "echo AFTER-$((1+1))\r")
        let text = await output.value

        XCTAssertEqual(decisions.requests.count, 2, shell)
        XCTAssertEqual(decisions.requests.first?.target, .local(.unleashed))
        XCTAssertFalse(text.contains("DENIED-42"), "\(shell): \(text)")
        XCTAssertTrue(text.contains("ALLOWED-42"), "\(shell): \(text)")
        await session.close()
    }

    func testProcessRunnerCollectsOutputAndStatus() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 5"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(result.stdoutText, "out\n")
        XCTAssertEqual(result.stderrText, "err\n")
        XCTAssertEqual(result.status, 5)
    }
}

final class CommandGuardTests: XCTestCase {
    func testGuardSuspendedInAlternateScreenAndPasswordPrompts() {
        var guardState = CommandGuard()
        XCTAssertEqual(guardState.observeInput(Array("ls\r".utf8)), .forward)
        guard case .confirm = guardState.observeInput(Array("sudo reboot\r".utf8)) else { return XCTFail() }

        guardState.observeOutput(Array("\u{1B}[?1049h".utf8))
        XCTAssertEqual(guardState.observeInput(Array("sudo reboot\r".utf8)), .forward)
        guardState.observeOutput(Array("\u{1B}[?1049l$ ".utf8))
        guard case .confirm = guardState.observeInput(Array("sudo reboot\r".utf8)) else { return XCTFail() }

        guardState.observeOutput(Array("[sudo] password for mobile: ".utf8))
        XCTAssertEqual(guardState.observeInput(Array("rm -rf /usr/x\r".utf8)), .forward)
    }

    func testBackspaceAndCtrlUAreTracked() {
        var guardState = CommandGuard()
        XCTAssertEqual(guardState.observeInput(Array("sudoX".utf8) + [0x7F, 0x7F, 0x7F, 0x7F, 0x7F] + Array("ls\r".utf8)), .forward)
        XCTAssertEqual(guardState.observeInput(Array("sudo x".utf8) + [0x15] + Array("pwd\r".utf8)), .forward)
    }
}

final class PackageAndLocationTests: XCTestCase {
    func testPackageCommandsAreExactAndRequireAuthorization() async throws {
        let scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.rootlessDevice).scan()
        let declined = PackageManagerClient(scan: scan, gate: AuthorizationGate(presenter: { _ in false }))
        XCTAssertEqual(try declined.commandLine(for: .install("htop")), "/var/jb/usr/bin/apt install htop")
        XCTAssertFalse(try declined.commandLine(for: .remove("htop")).contains("sudo"))
        XCTAssertThrowsError(try declined.commandLine(for: .install("htop; rm -rf /")))
        do {
            _ = try await declined.authorizedCommand(for: .install("htop"))
            XCTFail("declined must throw")
        } catch { XCTAssertEqual(error as? PackageManagerError, .declined) }

        let approved = PackageManagerClient(scan: scan, gate: AuthorizationGate(presenter: { _ in true }))
        let command = try await approved.authorizedCommand(for: .install("htop"))
        XCTAssertEqual(command, "/var/jb/usr/bin/apt install htop")
    }

    func testLocationBrowserStaysInsidePermittedRoots() throws {
        let scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.rootlessDevice).scan()
        let browser = PermittedLocationBrowser(scan: scan)
        XCTAssertEqual(Set(browser.roots), ["/var/jb", "/var/mobile"])
        XCTAssertThrowsError(try browser.list("/etc"))
        XCTAssertThrowsError(try browser.list("/var/mobile/../../etc"))
        XCTAssertThrowsError(try browser.readTail("/var/jbx/secret"))
    }
}

final class VanillaProviderTests: XCTestCase {
    func testVanillaReportAndSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-v-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try FileWorkspace(rootURL: root)
        let capabilities = VanillaCapabilityProvider(workspace: workspace)
        let report = await capabilities.detectCapabilities()
        XCTAssertTrue(report.localFeaturesAvailable)
        XCTAssertEqual(report[.executableAccess].availability.isUsable, false)
        XCTAssertEqual(report[.privilegedOperations].availability.isUsable, false)
        XCTAssertEqual(report[.remoteSSH].availability, .available)

        let provider = VanillaExecutionProvider(workspace: workspace, capabilities: capabilities)
        let session = try await provider.makeSession()
        XCTAssertEqual(session.target, .local(.vanilla))
        XCTAssertEqual(session.backend, .builtInCommands)
        let shell = try XCTUnwrap(session as? BuiltinShellSession)
        let status = await shell.runForTesting("python3 -c 'print(1)'")
        XCTAssertEqual(status, 127)
    }

    func testStandardBuildPlaceholderReportsUnleashedUnavailable() async {
        let report = await UnleashedNotIncludedCapabilityProvider().detectCapabilities()
        XCTAssertFalse(report.localFeaturesAvailable)
        XCTAssertEqual(report.headline, CapabilityReport.unleashedUnavailableMessage)
        XCTAssertEqual(report[.remoteSSH].availability, .available)
    }
}
