import FileWorkspace
import Foundation
@testable import LocalCommandEngine
import TerminalCore
import XCTest

final class CommandParserTests: XCTestCase {
    func testQuotingAndExpansion() throws {
        let list = try CommandParser.parse(#"echo 'a b' "c $X" d\ e ${Y}z $?"#, environment: ["X": "1", "Y": "2"], lastStatus: 3)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items[0].pipeline.commands[0].arguments, ["echo", "a b", "c 1", "d e", "2z", "3"])
    }

    func testOperators() throws {
        let list = try CommandParser.parse("ls | grep x > out.txt && echo ok || echo no ; pwd # comment")
        XCTAssertEqual(list.items.count, 4)
        XCTAssertEqual(list.items[0].pipeline.commands.count, 2)
        XCTAssertEqual(list.items[0].pipeline.commands[1].redirections, [.output("out.txt", append: false)])
        XCTAssertEqual(list.items.map(\.connector), [.and, .or, .sequence, .sequence])
    }

    func testErrors() {
        XCTAssertThrowsError(try CommandParser.parse("echo 'open"))
        XCTAssertThrowsError(try CommandParser.parse("| ls"))
        XCTAssertThrowsError(try CommandParser.parse("ls &&"))
        XCTAssertThrowsError(try CommandParser.parse("ls >"))
        XCTAssertThrowsError(try CommandParser.parse("sleep 1 &"))
    }

    func testQuotedGlobIsNotGlobbable() throws {
        let words = try CommandParser.parse("ls *.txt '*.md'").items[0].pipeline.commands[0].words
        XCTAssertTrue(words[1].globbable)
        XCTAssertFalse(words[2].globbable)
    }

    func testGlob() {
        XCTAssertTrue(Glob.matches("main.swift", pattern: "*.swift"))
        XCTAssertTrue(Glob.matches("a1", pattern: "a[0-9]"))
        XCTAssertFalse(Glob.matches("ab", pattern: "a[!b]"))
        XCTAssertTrue(Glob.matches("x.y", pattern: "?.?"))
        XCTAssertFalse(Glob.matches("main.swift", pattern: "*.md"))
    }
}

final class LineEditorTests: XCTestCase {
    func testTypingAndSubmit() {
        var editor = LineEditor()
        XCTAssertEqual(editor.feed(Array("ls".utf8)), [.echo(Array("ls".utf8))])
        let actions = editor.feed([0x0D])
        XCTAssertEqual(actions.last, .submit("ls"))
        XCTAssertEqual(editor.line, "")
    }

    func testBackspaceCursorAndHistory() {
        var editor = LineEditor()
        _ = editor.feed(Array("abc".utf8))
        _ = editor.feed([0x7F])
        XCTAssertEqual(editor.line, "ab")
        _ = editor.feed(Array("\u{1B}[D".utf8))  // left
        _ = editor.feed(Array("X".utf8))
        XCTAssertEqual(editor.line, "aXb")
        _ = editor.feed([0x0D])
        editor.addHistory("aXb")
        _ = editor.feed(Array("\u{1B}[A".utf8))  // up
        XCTAssertEqual(editor.line, "aXb")
        _ = editor.feed(Array("\u{1B}[B".utf8))  // down
        XCTAssertEqual(editor.line, "")
    }

    func testControlKeys() {
        var editor = LineEditor()
        _ = editor.feed(Array("one two".utf8))
        _ = editor.feed([0x17]) // Ctrl-W
        XCTAssertEqual(editor.line, "one ")
        XCTAssertEqual(editor.feed([0x03]).last, .interrupt)
        XCTAssertEqual(editor.feed([0x04]), [.endOfInput])
        XCTAssertEqual(editor.feed([0x09]), [.complete(prefix: "")])
    }

    func testMultibyteUTF8SplitAcrossFeeds() {
        var editor = LineEditor()
        let bytes = Array("é".utf8)
        _ = editor.feed([bytes[0]])
        _ = editor.feed([bytes[1]])
        XCTAssertEqual(editor.line, "é")
    }
}

final class BuiltinShellSessionTests: XCTestCase {
    var root: URL!
    var workspace: FileWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-sh-\(UUID().uuidString)")
        workspace = try FileWorkspace(rootURL: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeSession(handler: any ExternalCommandHandler = RefusingExternalCommandHandler(policyDescription: "", explanation: "Not in Vanilla.")) -> BuiltinShellSession {
        BuiltinShellSession(
            configuration: BuiltinShellConfiguration(
                target: .local(.vanilla), workspace: workspace, environment: ["USER": "tester"], banner: "hi\n",
                promptLabel: "vanilla", promptColor: ANSI.blue, sessionDescription: ["Target: Local Vanilla"],
                capabilityDescription: { "caps" }
            ),
            external: handler
        )
    }

    func testCommandsOperateOnWorkspace() async throws {
        let session = makeSession()
        var status = await session.runForTesting("mkdir -p proj/src && cd proj && echo hello > src/a.txt && echo world >> src/a.txt")
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try workspace.readText(WorkspacePath("/home/proj/src/a.txt")), "hello\nworld\n")
        status = await session.runForTesting("cat src/a.txt | grep -c o > count.txt")
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try workspace.readText(WorkspacePath("/home/proj/count.txt")), "2\n")
        status = await session.runForTesting("cp src/*.txt . && ls")
        XCTAssertEqual(status, 0)
        XCTAssertTrue(workspace.exists(try WorkspacePath("/home/proj/a.txt")))
        status = await session.runForTesting("false && touch never.txt || touch fallback.txt")
        XCTAssertEqual(status, 0)
        XCTAssertFalse(workspace.exists(try WorkspacePath("/home/proj/never.txt")))
        XCTAssertTrue(workspace.exists(try WorkspacePath("/home/proj/fallback.txt")))
    }

    func testRmRefusesWorkspaceRootAndCurrentDirectory() async throws {
        let session = makeSession()
        let status = await session.runForTesting("rm -rf /")
        XCTAssertEqual(status, 1)
        XCTAssertTrue(workspace.isDirectory(.home))
    }

    func testExternalCommandIsRefusedAndNeverForwarded() async throws {
        final class Recorder: ExternalCommandHandler, @unchecked Sendable {
            var calls: [[String]] = []
            let policyDescription = ""
            func run(_ request: ExternalCommandRequest, output: @escaping @Sendable (Data, Bool) -> Void) async -> Int32 {
                calls.append(request.arguments)
                return await RefusingExternalCommandHandler(policyDescription: "", explanation: "x").run(request, output: output)
            }
        }
        let recorder = Recorder()
        let session = makeSession(handler: recorder)
        let status = await session.runForTesting("ssh build-mac uptime")
        XCTAssertEqual(status, 127)
        XCTAssertEqual(recorder.calls, [["ssh", "build-mac", "uptime"]])
    }

    func testInteractiveTypingProducesOutput() async throws {
        let session = makeSession()
        let collected = Task { () -> String in
            var text = ""
            for await event in session.events {
                if case .output(let bytes) = event { text += String(decoding: bytes, as: UTF8.self) }
                if text.contains("hello-from-test") && text.hasSuffix("$ ") && text.components(separatedBy: "$ ").count >= 3 { break }
            }
            return text
        }
        try await session.start(size: .standard)
        try await session.send(text: "echo hello-from-test\r")
        let text = await collected.value
        XCTAssertTrue(text.contains("hi"))
        XCTAssertTrue(text.contains("hello-from-test\r\n"))
        await session.close()
    }
}
