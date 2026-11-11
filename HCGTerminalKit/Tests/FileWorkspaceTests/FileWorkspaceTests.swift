import FileWorkspace
import Foundation
import XCTest

final class WorkspacePathTests: XCTestCase {
    func testResolution() throws {
        XCTAssertEqual(try WorkspacePath("/a/b/../c").string, "/a/c")
        XCTAssertEqual(try WorkspacePath("x/./y", relativeTo: WorkspacePath("/home")).string, "/home/x/y")
        XCTAssertEqual(try WorkspacePath("~").string, "/home")
        XCTAssertEqual(try WorkspacePath("~/p").string, "/home/p")
        // `..` cannot climb above the workspace root.
        XCTAssertEqual(try WorkspacePath("../../../../etc/passwd", relativeTo: .home).string, "/etc/passwd")
        XCTAssertEqual(try WorkspacePath("/home/projects").display(), "~/projects")
        XCTAssertThrowsError(try WorkspacePath("bad\0name"))
    }
}

final class FileWorkspaceTests: XCTestCase {
    var root: URL!
    var workspace: FileWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-ws-\(UUID().uuidString)")
        workspace = try FileWorkspace(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStandardDirectoriesExist() {
        for directory in FileWorkspace.standardDirectories {
            XCTAssertTrue(workspace.isDirectory(directory), directory.string)
        }
    }

    func testDotDotNeverLeavesTheSandbox() throws {
        let path = try WorkspacePath("../../../../../etc/passwd", relativeTo: .home)
        let url = try workspace.url(for: path)
        XCTAssertTrue(url.path.hasPrefix(root.standardizedFileURL.path), url.path)
        XCTAssertFalse(workspace.exists(path))
    }

    func testSymlinkEscapeIsRejected() throws {
        let link = root.appendingPathComponent("home/escape")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc")
        XCTAssertThrowsError(try workspace.list(WorkspacePath("/home/escape"))) { error in
            XCTAssertEqual(error as? WorkspaceError, .escapesWorkspace("/home/escape"))
        }
        XCTAssertThrowsError(try workspace.readText(WorkspacePath("/home/escape/hostname")))
    }

    func testFileOperations() throws {
        let file = try WorkspacePath("/home/notes.txt")
        try workspace.write("one\n", to: file)
        try workspace.write("two\n", to: file, append: true)
        XCTAssertEqual(try workspace.readText(file), "one\ntwo\n")

        try workspace.createDirectory(WorkspacePath("/home/a/b"), intermediates: true)
        try workspace.copy(file, to: WorkspacePath("/home/a"))
        XCTAssertTrue(workspace.exists(try WorkspacePath("/home/a/notes.txt")))
        try workspace.move(WorkspacePath("/home/a/notes.txt"), to: WorkspacePath("/home/a/b/renamed.txt"))
        XCTAssertEqual(try workspace.list(WorkspacePath("/home/a/b")).map(\.name), ["renamed.txt"])

        XCTAssertThrowsError(try workspace.remove(WorkspacePath("/home/a"))) { error in
            XCTAssertEqual(error as? WorkspaceError, .directoryNotEmpty("/home/a"))
        }
        try workspace.remove(WorkspacePath("/home/a"), recursive: true)
        XCTAssertFalse(workspace.exists(try WorkspacePath("/home/a")))
        XCTAssertThrowsError(try workspace.remove(.root))
    }

    func testCannotMoveDirectoryIntoItself() throws {
        try workspace.createDirectory(WorkspacePath("/home/d"))
        XCTAssertThrowsError(try workspace.move(WorkspacePath("/home/d"), to: WorkspacePath("/home/d/inner")))
    }
}
