import Foundation
import TerminalCore

/// An absolute path inside the workspace. `/` is the workspace root, never the device root.
public struct WorkspacePath: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let components: [String]

    public static let root = WorkspacePath(components: [])
    public static let home = WorkspacePath(components: ["home"])
    public static let projects = WorkspacePath(components: ["projects"])
    public static let artifacts = WorkspacePath(components: ["artifacts"])
    public static let logs = WorkspacePath(components: ["logs"])
    public static let tmp = WorkspacePath(components: ["tmp"])

    public init(components: [String]) { self.components = components }

    /// Resolves `path` (absolute, relative, `~`, `.`, `..`) against `base`.
    /// `..` at the root stays at the root, exactly like a real filesystem root.
    public init(_ path: String, relativeTo base: WorkspacePath = .root, home: WorkspacePath = .home) throws {
        guard !path.contains("\0") else { throw WorkspaceError.invalidName(path) }
        var result: [String]
        var remainder = Substring(path)
        if path == "~" || path.hasPrefix("~/") {
            result = home.components
            remainder = path.dropFirst(1)
        } else if path.hasPrefix("/") {
            result = []
        } else {
            result = base.components
        }
        for part in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(String(part))
            }
        }
        self.components = result
    }

    public var string: String { "/" + components.joined(separator: "/") }
    public var description: String { string }
    public var name: String { components.last ?? "/" }
    public var parent: WorkspacePath { WorkspacePath(components: Array(components.dropLast())) }
    public var isRoot: Bool { components.isEmpty }

    public func appending(_ name: String) -> WorkspacePath { WorkspacePath(components: components + [name]) }

    public func isDescendant(of other: WorkspacePath) -> Bool {
        components.count > other.components.count && Array(components.prefix(other.components.count)) == other.components
    }

    /// Display form with the home directory abbreviated to `~`.
    public func display(home: WorkspacePath = .home) -> String {
        if self == home { return "~" }
        if isDescendant(of: home) { return "~/" + components.dropFirst(home.components.count).joined(separator: "/") }
        return string
    }

    public static func < (lhs: WorkspacePath, rhs: WorkspacePath) -> Bool { lhs.string < rhs.string }
}

public enum WorkspaceError: Error, LocalizedError, Equatable, Sendable {
    case notFound(String)
    case notADirectory(String)
    case isADirectory(String)
    case alreadyExists(String)
    case directoryNotEmpty(String)
    case invalidName(String)
    case escapesWorkspace(String)
    case operationNotPermitted(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): "\(p): No such file or directory"
        case .notADirectory(let p): "\(p): Not a directory"
        case .isADirectory(let p): "\(p): Is a directory"
        case .alreadyExists(let p): "\(p): File exists"
        case .directoryNotEmpty(let p): "\(p): Directory not empty"
        case .invalidName(let p): "\(p): Invalid name"
        case .escapesWorkspace(let p): "\(p): Outside the app sandbox workspace"
        case .operationNotPermitted(let p): "\(p): Operation not permitted"
        case .io(let message): message
        }
    }
}

public struct WorkspaceItem: Hashable, Sendable, Identifiable {
    public var path: WorkspacePath
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public var id: WorkspacePath { path }
    public var name: String { path.name }
}

/// The local filesystem available to Vanilla sessions: a directory inside the app container.
///
/// Every operation maps a `WorkspacePath` to a URL under `rootURL` and verifies, after
/// resolving symbolic links, that the result is still inside the root.
public final class FileWorkspace: Sendable {
    public let rootURL: URL
    private let resolvedRootPath: String

    public static let standardDirectories: [WorkspacePath] = [.home, .projects, .artifacts, .logs, .tmp]

    public init(rootURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL.standardizedFileURL
        self.resolvedRootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        for directory in Self.standardDirectories {
            try fm.createDirectory(at: rootURL.appendingPathComponent(directory.components.joined(separator: "/")), withIntermediateDirectories: true)
        }
    }

    /// `Documents/Workspace` inside the app container, visible in the Files app when the app
    /// enables document browsing.
    public static func appContainerDefault() throws -> FileWorkspace {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try FileWorkspace(rootURL: documents.appendingPathComponent("Workspace", isDirectory: true))
    }

    // MARK: Mapping

    public func url(for path: WorkspacePath) throws -> URL {
        let url = path.components.reduce(rootURL) { $0.appendingPathComponent($1) }
        try verifyContained(url, display: path.string)
        return url
    }

    private func verifyContained(_ url: URL, display: String) throws {
        // Resolve symlinks on the deepest existing ancestor; a new file's own name cannot be a link yet.
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let resolved = probe.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == resolvedRootPath || resolved.hasPrefix(resolvedRootPath + "/") else {
            throw WorkspaceError.escapesWorkspace(display)
        }
        // If the final component exists and is a symlink, verify its destination too.
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).resolvingSymlinksInPath().standardizedFileURL.path
            guard target == resolvedRootPath || target.hasPrefix(resolvedRootPath + "/") else {
                throw WorkspaceError.escapesWorkspace(display)
            }
        }
    }

    // MARK: Queries

    public func exists(_ path: WorkspacePath) -> Bool {
        guard let url = try? url(for: path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(_ path: WorkspacePath) -> Bool {
        guard let url = try? url(for: path) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func item(at path: WorkspacePath) throws -> WorkspaceItem {
        let url = try url(for: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw WorkspaceError.notFound(path.string)
        }
        let type = attributes[.type] as? FileAttributeType
        return WorkspaceItem(
            path: path,
            isDirectory: type == .typeDirectory,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
    }

    public func list(_ path: WorkspacePath, includeHidden: Bool = false) throws -> [WorkspaceItem] {
        _ = try url(for: path)
        guard exists(path) else { throw WorkspaceError.notFound(path.string) }
        guard isDirectory(path) else { throw WorkspaceError.notADirectory(path.string) }
        let names = try FileManager.default.contentsOfDirectory(atPath: url(for: path).path)
        return try names
            .filter { includeHidden || !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { try item(at: path.appending($0)) }
    }

    // MARK: Reading and writing

    public func readData(_ path: WorkspacePath, limit: Int = 16 * 1024 * 1024) throws -> Data {
        _ = try url(for: path)
        guard exists(path) else { throw WorkspaceError.notFound(path.string) }
        guard !isDirectory(path) else { throw WorkspaceError.isADirectory(path.string) }
        let handle = try FileHandle(forReadingFrom: url(for: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }

    public func readText(_ path: WorkspacePath) throws -> String {
        String(decoding: try readData(path), as: UTF8.self)
    }

    public func write(_ data: Data, to path: WorkspacePath, append: Bool = false) throws {
        guard !path.isRoot else { throw WorkspaceError.isADirectory("/") }
        guard isDirectory(path.parent) else { throw WorkspaceError.notFound(path.parent.string) }
        guard !isDirectory(path) else { throw WorkspaceError.isADirectory(path.string) }
        let url = try url(for: path)
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }

    public func write(_ text: String, to path: WorkspacePath, append: Bool = false) throws {
        try write(Data(text.utf8), to: path, append: append)
    }

    /// Creates or updates the modification date of a file (like `touch`).
    public func touch(_ path: WorkspacePath) throws {
        if exists(path) {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: path).path)
        } else {
            try write(Data(), to: path)
        }
    }

    public func createDirectory(_ path: WorkspacePath, intermediates: Bool = false) throws {
        if exists(path) {
            if intermediates && isDirectory(path) { return }
            throw WorkspaceError.alreadyExists(path.string)
        }
        if !intermediates, !isDirectory(path.parent) { throw WorkspaceError.notFound(path.parent.string) }
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: intermediates)
    }

    public func remove(_ path: WorkspacePath, recursive: Bool = false) throws {
        guard !path.isRoot else { throw WorkspaceError.operationNotPermitted("/") }
        guard exists(path) else { throw WorkspaceError.notFound(path.string) }
        if isDirectory(path), !recursive {
            if try !list(path, includeHidden: true).isEmpty { throw WorkspaceError.directoryNotEmpty(path.string) }
        }
        try FileManager.default.removeItem(at: url(for: path))
    }

    public func move(_ source: WorkspacePath, to destination: WorkspacePath) throws {
        let target = isDirectory(destination) ? destination.appending(source.name) : destination
        try checkTransfer(source, target)
        try FileManager.default.moveItem(at: url(for: source), to: url(for: target))
    }

    public func copy(_ source: WorkspacePath, to destination: WorkspacePath) throws {
        let target = isDirectory(destination) ? destination.appending(source.name) : destination
        try checkTransfer(source, target)
        try FileManager.default.copyItem(at: url(for: source), to: url(for: target))
    }

    private func checkTransfer(_ source: WorkspacePath, _ target: WorkspacePath) throws {
        guard !source.isRoot else { throw WorkspaceError.operationNotPermitted("/") }
        guard exists(source) else { throw WorkspaceError.notFound(source.string) }
        guard !exists(target) else { throw WorkspaceError.alreadyExists(target.string) }
        guard target != source, !target.isDescendant(of: source) else { throw WorkspaceError.operationNotPermitted(target.string) }
        guard isDirectory(target.parent) else { throw WorkspaceError.notFound(target.parent.string) }
    }

    /// Bytes used by everything under `path`.
    public func diskUsage(_ path: WorkspacePath) throws -> Int64 {
        let base = try url(for: path)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
