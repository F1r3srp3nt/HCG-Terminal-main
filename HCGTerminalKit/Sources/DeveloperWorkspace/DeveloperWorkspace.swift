import Foundation
import TerminalCore

// MARK: - Host profiles

public enum HostAuthMethod: Codable, Hashable, Sendable {
    /// Password stored in the Keychain under `CredentialKey.hostPassword(hostID)`.
    case password
    /// Ed25519 key generated on the device, stored in the Keychain.
    case key(UUID)
    /// Key first, then the stored password.
    case keyThenPassword(UUID)
}

/// A saved remote host. Contains no secrets.
public struct HostProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var auth: HostAuthMethod
    /// Where project browsing starts, e.g. `~/Developer`.
    public var projectsPath: String?

    public init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22, username: String, auth: HostAuthMethod, projectsPath: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.projectsPath = projectsPath
    }

    public var endpoint: RemoteEndpoint {
        RemoteEndpoint(hostID: id, displayName: name, hostname: hostname, port: port, username: username)
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostname.contains(" ")
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
    }
}

public actor HostProfileStore {
    private let fileURL: URL?
    private var profiles: [HostProfile]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
    }

    public func all() -> [HostProfile] { profiles }

    public func save(_ profile: HostProfile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        try persist()
    }

    public func delete(_ id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Remote shell helpers

public enum RemoteShell {
    /// Wraps `command` in the remote user's login shell, so PATH matches what they get in
    /// Terminal (Homebrew, dotnet, ~/.local/bin for Claude Code, …).
    public static func login(_ command: String) -> String {
        "exec \"${SHELL:-/bin/sh}\" -lc \(ShellQuote.quote(command))"
    }

    /// `cd` into `path` (with `~` support) and run `command`.
    public static func inDirectory(_ path: String, _ command: String) -> String {
        "cd \(quotePath(path)) && \(command)"
    }

    /// Quotes a remote path while keeping a leading `~/` expandable.
    public static func quotePath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + ShellQuote.quote(String(path.dropFirst(2))) }
        return ShellQuote.quote(path)
    }
}

// MARK: - Remote browsing

public struct RemoteEntry: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case directory, file, symlink, other }
    public var name: String
    public var path: String
    public var kind: Kind
    public var size: Int64?
    public var id: String { path }
}

public enum ProjectKind: Hashable, Sendable {
    case swiftPackage
    case xcodeProject(String)
    case xcodeWorkspace(String)
    case dotnetSolution(String)
    case dotnetProject(String)

    public var label: String {
        switch self {
        case .swiftPackage: "Swift package"
        case .xcodeProject(let name): "Xcode project · \(name)"
        case .xcodeWorkspace(let name): "Xcode workspace · \(name)"
        case .dotnetSolution(let name): ".NET solution · \(name)"
        case .dotnetProject(let name): ".NET project · \(name)"
        }
    }
}

public enum ProjectDetector {
    public static func detect(_ entries: [RemoteEntry]) -> [ProjectKind] {
        var kinds: [ProjectKind] = []
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            switch entry.kind {
            case .directory:
                if entry.name.hasSuffix(".xcworkspace") { kinds.append(.xcodeWorkspace(entry.name)) }
                if entry.name.hasSuffix(".xcodeproj") { kinds.append(.xcodeProject(entry.name)) }
            case .file, .symlink:
                if entry.name == "Package.swift" { kinds.append(.swiftPackage) }
                if entry.name.hasSuffix(".sln") { kinds.append(.dotnetSolution(entry.name)) }
                if entry.name.hasSuffix(".csproj") || entry.name.hasSuffix(".fsproj") { kinds.append(.dotnetProject(entry.name)) }
            case .other:
                break
            }
        }
        return kinds
    }
}

public enum RemoteBrowserError: Error, LocalizedError, Equatable {
    case listingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .listingFailed(let message): message
        }
    }
}

/// Browses directories on a remote host using portable POSIX shell (works on macOS and Linux).
public struct RemoteProjectBrowser: Sendable {
    private let executor: any RemoteCommandExecuting

    public init(executor: any RemoteCommandExecuting) {
        self.executor = executor
    }

    public func homeDirectory() async throws -> String {
        let result = try await executor.run("printf '%s' \"$HOME\"")
        guard result.succeeded, !result.stdoutText.isEmpty else { throw RemoteBrowserError.listingFailed(result.stderrText) }
        return result.stdoutText
    }

    static func listingScript(_ path: String) -> String {
        """
        cd \(RemoteShell.quotePath(path)) || exit 2; printf '%s\\n' "$PWD"; \
        for f in .[!.]* ..?* *; do \
        [ -e "$f" ] || [ -L "$f" ] || continue; \
        if [ -L "$f" ]; then t=l; elif [ -d "$f" ]; then t=d; elif [ -f "$f" ]; then t=f; else t=o; fi; \
        if [ "$t" = f ]; then s=$(wc -c < "$f" 2>/dev/null | tr -d ' '); else s=-; fi; \
        printf '%s\\t%s\\t%s\\n' "$t" "$s" "$f"; done
        """
    }

    /// Lists `path` (absolute or `~`-relative). Returns the resolved directory and its entries.
    public func list(_ path: String) async throws -> (directory: String, entries: [RemoteEntry]) {
        let result = try await executor.run(Self.listingScript(path))
        guard result.succeeded else {
            throw RemoteBrowserError.listingFailed(result.stderrText.isEmpty ? "Could not list \(path)." : result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Self.parseListing(result.stdoutText)
    }

    static func parseListing(_ output: String) -> (directory: String, entries: [RemoteEntry]) {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return ("", []) }
        let directory = lines.removeFirst()
        let entries: [RemoteEntry] = lines.compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            let kind: RemoteEntry.Kind = switch fields[0] {
            case "d": .directory
            case "f": .file
            case "l": .symlink
            default: .other
            }
            let path = directory == "/" ? "/" + fields[2] : directory + "/" + fields[2]
            return RemoteEntry(name: fields[2], path: path, kind: kind, size: Int64(fields[1]))
        }
        .sorted { ($0.kind == .directory ? 0 : 1, $0.name.lowercased()) < ($1.kind == .directory ? 0 : 1, $1.name.lowercased()) }
        return (directory, entries)
    }
}

// MARK: - Toolchains

public struct RemoteToolchains: Hashable, Sendable {
    public var tools: [String: String]   // name → path
    public var operatingSystem: String

    public func has(_ tool: String) -> Bool { tools[tool] != nil }
}

public enum ToolchainProbe {
    public static let tools = ["swift", "xcodebuild", "xcrun", "dotnet", "claude", "git"]

    /// Read-only: `uname` and `command -v` in the remote login shell.
    public static func probe(_ executor: any RemoteCommandExecuting) async throws -> RemoteToolchains {
        let script = "uname -sr; " + tools.map { "printf '%s\\t%s\\n' \($0) \"$(command -v \($0) 2>/dev/null)\"" }.joined(separator: "; ")
        let result = try await executor.run(RemoteShell.login(script))
        var lines = result.stdoutText.split(separator: "\n").map(String.init)
        let os = lines.isEmpty ? "" : lines.removeFirst()
        var found: [String: String] = [:]
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2, !fields[1].isEmpty { found[fields[0]] = fields[1] }
        }
        return RemoteToolchains(tools: found, operatingSystem: os)
    }
}

/// Lists schemes of an Xcode project or workspace via `xcodebuild -list -json`.
public enum XcodeSchemeLister {
    public static func command(projectDirectory: String, container: ProjectKind) -> String? {
        let flag: String
        switch container {
        case .xcodeProject(let name): flag = "-project \(ShellQuote.quote(name))"
        case .xcodeWorkspace(let name): flag = "-workspace \(ShellQuote.quote(name))"
        default: return nil
        }
        return RemoteShell.login(RemoteShell.inDirectory(projectDirectory, "xcodebuild -list -json \(flag)"))
    }

    public static func parse(_ json: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        let container = (object["project"] ?? object["workspace"]) as? [String: Any]
        return (container?["schemes"] as? [String]) ?? []
    }
}

/// Builds the command that starts Claude Code in a project on a remote host. It is run in an
/// SSH PTY session, so Claude Code executes on the remote host, never on this device.
public enum ClaudeCodeLauncher {
    public static func command(projectPath: String, arguments: [String] = []) -> String {
        let claude = (["claude"] + arguments.map(ShellQuote.quote)).joined(separator: " ")
        return RemoteShell.login(RemoteShell.inDirectory(projectPath, "exec \(claude)"))
    }
}
