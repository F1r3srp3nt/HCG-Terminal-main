import ArtifactManager
import BuildOrchestrator
import Crypto
import DeveloperWorkspace
import FileWorkspace
import Foundation
import RemoteSSH
import TerminalCore
import TerminalSecurity
import XCTest

/// End-to-end: browse, build, test and download an artifact on a real SSH host.
/// Needs `Scripts/start-test-sshd.sh` and a `swift` toolchain for the `hcgtest` user.
final class RemoteDevelopmentIntegrationTests: XCTestCase {
    func testBrowseBuildTestAndDownloadOverSSH() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1")
        let host = HostProfile(name: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest", auth: .password)
        let knownHosts = KnownHostsStore(fileURL: nil)
        let connection = try await SSHConnection.connect(
            endpoint: host.endpoint, authentication: .password("hcg-test-pass"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _, _, _ in true }
        )

        let toolchains = try await ToolchainProbe.probe(connection)
        try XCTSkipUnless(toolchains.has("swift"), "no swift on the test host")

        // Create a small package with one test.
        let project = "~/hcg-demo-\(UUID().uuidString.prefix(6))"
        let setup = try await connection.run(RemoteShell.login("""
        mkdir -p \(RemoteShell.quotePath(project)) && cd \(RemoteShell.quotePath(project)) && \
        swift package init --type executable --name HCGDemo >/dev/null && \
        mkdir -p Tests/HCGDemoTests && printf '%s\\n' 'import XCTest' 'final class T: XCTestCase { func testOK() { XCTAssertEqual(1 + 1, 2) } }' > Tests/HCGDemoTests/T.swift && \
        cat > Package.swift <<'EOF'
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "HCGDemo", targets: [
            .executableTarget(name: "HCGDemo", path: "Sources"),
            .testTarget(name: "HCGDemoTests", path: "Tests/HCGDemoTests"),
        ])
        EOF
        """))
        XCTAssertEqual(setup.status, 0, setup.stderrText)

        let browser = RemoteProjectBrowser(executor: connection)
        let listing = try await browser.list(project)
        XCTAssertTrue(ProjectDetector.detect(listing.entries).contains(.swiftPackage))

        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-build-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logs) }
        let orchestrator = BuildOrchestrator(logDirectory: logs)

        let build = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: project, system: .swiftPackage, action: .build), on: connection)
        let buildLog = await orchestrator.log(for: build)
        XCTAssertEqual(build.status, .succeeded, buildLog)

        let test = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: project, system: .swiftPackage, action: .test), on: connection)
        let testLog = await orchestrator.log(for: test)
        XCTAssertEqual(test.status, .succeeded, testLog)
        XCTAssertEqual(test.testSummary?.succeeded, true, testLog)
        XCTAssertEqual(test.testSummary?.failed, 0)

        let artifacts = try await ArtifactDiscovery.discover(for: build.plan, on: connection)
        let executable = try XCTUnwrap(artifacts.first { $0.name == "HCGDemo" }, "\(artifacts)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try FileWorkspace(rootURL: root)
        let index = ArtifactIndex(workspace: workspace)
        let record = try await ArtifactDownloader().download(remotePath: executable.remotePath, from: connection, into: workspace, index: index, buildRunID: build.id)
        XCTAssertEqual(record.verification, .remoteChecksumMatched)
        let local = try workspace.readData(WorkspacePath(record.localPath), limit: .max)
        XCTAssertEqual(Int64(local.count), record.size)
        XCTAssertEqual(SHA256.hash(data: local).map { String(format: "%02x", $0) }.joined(), record.sha256)
        let indexed = await index.all()
        XCTAssertEqual(indexed.map(\.id), [record.id])

        _ = try await connection.run("rm -rf \(RemoteShell.quotePath(project))")
        await connection.close()
    }
}
