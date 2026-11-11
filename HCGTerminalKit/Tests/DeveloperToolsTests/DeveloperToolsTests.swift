import ArtifactManager
import BuildOrchestrator
@testable import DeveloperWorkspace
import FileWorkspace
import Foundation
import TerminalCore
import XCTest

/// Answers commands from a script instead of a network.
final class ScriptedExecutor: RemoteCommandExecuting, @unchecked Sendable {
    let endpoint: RemoteEndpoint
    var responses: [(match: String, events: [RemoteExecEvent])] = []
    var commands: [String] = []

    init(endpoint: RemoteEndpoint) { self.endpoint = endpoint }

    func stream(_ command: String) -> AsyncThrowingStream<RemoteExecEvent, Error> {
        commands.append(command)
        let events = responses.first(where: { command.contains($0.match) })?.events ?? [.exit(status: 127)]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

final class DeveloperWorkspaceTests: XCTestCase {
    func testListingParserAndProjectDetection() {
        let output = "/Users/ana/App\nd\t-\tApp.xcodeproj\nf\t120\tPackage.swift\nf\t50\tApp.sln\nl\t-\tlink\nd\t-\tSources\n"
        let (directory, entries) = RemoteProjectBrowser.parseListing(output)
        XCTAssertEqual(directory, "/Users/ana/App")
        XCTAssertEqual(entries.first?.kind, .directory)
        XCTAssertEqual(entries.first(where: { $0.name == "Package.swift" })?.size, 120)
        XCTAssertEqual(entries.first(where: { $0.name == "Sources" })?.path, "/Users/ana/App/Sources")
        XCTAssertEqual(Set(ProjectDetector.detect(entries)), [.swiftPackage, .xcodeProject("App.xcodeproj"), .dotnetSolution("App.sln")])
    }

    func testRemotePathQuoting() {
        XCTAssertEqual(RemoteShell.quotePath("~/My Apps"), "\"$HOME\"/'My Apps'")
        XCTAssertEqual(RemoteShell.quotePath("/tmp/x"), "/tmp/x")
        XCTAssertTrue(ClaudeCodeLauncher.command(projectPath: "~/Dev/App").contains("exec claude"))
    }

    func testSchemeParsing() {
        let json = Data(#"{"project":{"name":"App","schemes":["App","AppTests"]}}"#.utf8)
        XCTAssertEqual(XcodeSchemeLister.parse(json), ["App", "AppTests"])
    }

    func testHostProfileValidation() {
        XCTAssertTrue(HostProfile(name: "Mac", hostname: "mac.local", username: "ana", auth: .password).isValid)
        XCTAssertFalse(HostProfile(name: "Mac", hostname: "bad host", username: "ana", auth: .password).isValid)
        XCTAssertFalse(HostProfile(name: "Mac", hostname: "mac", port: 0, username: "ana", auth: .password).isValid)
    }
}

final class BuildPlannerTests: XCTestCase {
    let host = HostProfile(name: "Build Mac", hostname: "mac.local", username: "ana", auth: .password)

    func testPlans() throws {
        let spm = try BuildPlanner.plan(host: host, projectPath: "~/Dev/Kit", system: .swiftPackage, action: .test)
        XCTAssertEqual(spm.commandLine, "swift test -c debug")
        XCTAssertTrue(spm.remoteCommand.contains("-lc"))

        let xcode = try BuildPlanner.plan(host: host, projectPath: "~/Dev/App", system: .xcodeProject(name: "App.xcodeproj", scheme: "App", destination: .genericIOS), action: .build, configuration: .release)
        XCTAssertEqual(xcode.commandLine, "xcodebuild -project App.xcodeproj -scheme App -configuration Release -destination generic/platform=iOS -derivedDataPath .hcg-build/DerivedData CODE_SIGNING_ALLOWED=NO build")

        let sim = try BuildPlanner.plan(host: host, projectPath: "~/Dev/App", system: .xcodeWorkspace(name: "App.xcworkspace", scheme: "App", destination: .iOSSimulator(name: "iPhone 17")), action: .test)
        XCTAssertTrue(sim.commandLine.contains("'platform=iOS Simulator,name=iPhone 17'"))

        let dotnet = try BuildPlanner.plan(host: host, projectPath: "~/Dev/Api", system: .dotnet(target: "Api.sln"), action: .test)
        XCTAssertEqual(dotnet.commandLine, "dotnet test Api.sln -c Debug")
    }

    func testPublishingIsAlwaysBlocked() {
        for command in [
            "xcrun altool --upload-app -f App.ipa", "fastlane pilot upload", "fastlane ios beta", "fastlane deliver",
            "xcodebuild -exportArchive -archivePath a -exportOptionsPlist o.plist", "dotnet nuget push x.nupkg",
            "xcrun notarytool submit App.zip", "npm publish", "gh release create v1",
        ] {
            XCTAssertThrowsError(try BuildPlanner.custom(host: host, projectPath: "~", command: command), command)
        }
        XCTAssertNoThrow(try BuildPlanner.custom(host: host, projectPath: "~", command: "./scripts/test.sh --verbose"))
        XCTAssertNoThrow(try BuildPlanner.custom(host: host, projectPath: "~", command: "dotnet publish -c Release -o out"))
    }
}

final class BuildLogParserTests: XCTestCase {
    func testDiagnostics() {
        let swift = BuildLogParser.diagnostic(in: "/Users/a/App/main.swift:12:5: error: cannot find 'x' in scope")
        XCTAssertEqual(swift?.severity, .error)
        XCTAssertEqual(swift?.line, 12)
        XCTAssertEqual(swift?.column, 5)
        XCTAssertEqual(swift?.message, "cannot find 'x' in scope")

        let csharp = BuildLogParser.diagnostic(in: "/src/Api/Program.cs(7,13): warning CS0168: The variable 'e' is declared but never used [/src/Api/Api.csproj]")
        XCTAssertEqual(csharp?.severity, .warning)
        XCTAssertEqual(csharp?.file, "/src/Api/Program.cs")
        XCTAssertEqual(csharp?.message, "CS0168: The variable 'e' is declared but never used")
        XCTAssertNil(BuildLogParser.diagnostic(in: "Compiling App main.swift"))
    }

    func testTestSummaries() {
        XCTAssertEqual(BuildLogParser.testSummary(in: "\tExecuted 12 tests, with 1 failure (0 unexpected) in 0.5 seconds")?.failed, 1)
        XCTAssertEqual(BuildLogParser.testSummary(in: "✔ Test run with 5 tests passed after 0.01 seconds.")?.total, 5)
        let dotnet = BuildLogParser.testSummary(in: "Passed!  - Failed:     0, Passed:    12, Skipped:     1, Total:    13, Duration: 1 s")
        XCTAssertEqual(dotnet, TestSummary(passed: 12, failed: 0, skipped: 1, total: 13, succeeded: true))
        XCTAssertEqual(BuildLogParser.testSummary(in: "** TEST FAILED **")?.succeeded, false)
    }

    func testOrchestratorRecordsRunWithScriptedExecutor() async throws {
        let host = HostProfile(name: "Mac", hostname: "mac", username: "a", auth: .password)
        let executor = ScriptedExecutor(endpoint: host.endpoint)
        executor.responses = [("swift build", [.stdout(Data("main.swift:3:1: warning: unused\nBuild complete!\n".utf8)), .exit(status: 0)])]
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logs) }
        let orchestrator = BuildOrchestrator(logDirectory: logs)
        let run = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: "~/k", system: .swiftPackage, action: .build), on: executor)
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.warningCount, 1)
        let log = await orchestrator.log(for: run)
        XCTAssertTrue(log.contains("Build complete!"))
        let runs = await orchestrator.runs()
        XCTAssertEqual(runs.count, 1)
    }

    func testRunRefusesWrongHost() async throws {
        let host = HostProfile(name: "Mac", hostname: "mac", username: "a", auth: .password)
        let other = HostProfile(name: "Other", hostname: "other", username: "a", auth: .password)
        let executor = ScriptedExecutor(endpoint: other.endpoint)
        let orchestrator = BuildOrchestrator(logDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)"))
        let run = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: "~", system: .swiftPackage, action: .build), on: executor)
        guard case .couldNotStart = run.status else { return XCTFail() }
        XCTAssertTrue(executor.commands.isEmpty)
    }
}

final class ArtifactDownloaderTests: XCTestCase {
    func testChecksumMismatchDiscardsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try FileWorkspace(rootURL: root)
        let executor = ScriptedExecutor(endpoint: RemoteEndpoint(hostID: UUID(), displayName: "M", hostname: "m", username: "u"))
        executor.responses = [
            ("wc -c", [.stdout(Data("f\t5\n".utf8)), .exit(status: 0)]),
            ("shasum", [.stdout(Data("0000\n".utf8)), .exit(status: 0)]),
            ("cat --", [.stdout(Data("hello".utf8)), .exit(status: 0)]),
        ]
        do {
            _ = try await ArtifactDownloader().download(remotePath: "/tmp/a.bin", from: executor, into: workspace, index: ArtifactIndex(workspace: workspace))
            XCTFail("mismatch must throw")
        } catch let error as ArtifactError {
            guard case .checksumMismatch = error else { return XCTFail("\(error)") }
        }
        let day = try workspace.list(.artifacts).filter(\.isDirectory)
        XCTAssertTrue(try day.allSatisfy { try workspace.list($0.path).isEmpty })
    }
}
