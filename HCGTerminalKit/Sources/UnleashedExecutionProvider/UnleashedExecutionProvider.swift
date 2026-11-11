import Diagnostics
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity

/// Creates Local Unleashed sessions. This module is linked only by the Unleashed app target;
/// the standard (Vanilla) build uses `UnleashedNotIncludedCapabilityProvider` instead.
public struct UnleashedExecutionProvider: LocalExecutionProvider {
    public let mode: ExecutionMode = .unleashed
    public let capabilities: UnleashedCapabilityProvider
    public let observations: RuntimeObservations
    public let gate: AuthorizationGate

    public init(capabilities: UnleashedCapabilityProvider, observations: RuntimeObservations, gate: AuthorizationGate) {
        self.capabilities = capabilities
        self.observations = observations
        self.gate = gate
    }

    public func availableBackend() async -> SessionBackend? {
        let scan = capabilities.scan()
        if let shell = scan.shells.first {
            if case .failed? = await observations.outcome(for: shell) {
                return scan.loopbackServicePorts.first.map { .loopbackService(host: "127.0.0.1", port: $0) }
            }
            return .localProcess(executable: shell)
        }
        return scan.loopbackServicePorts.first.map { .loopbackService(host: "127.0.0.1", port: $0) }
    }

    /// Creates a direct process session. Loopback terminal services are opened through
    /// RemoteSSH by the interface layer (with target Local Unleashed), because they need
    /// the service's own credentials.
    public func makeSession() async throws -> any TerminalSession {
        let scan = capabilities.scan()
        guard let shell = scan.shells.first else {
            throw ExecutionError.modeUnavailable(.unleashed, reason: "No local shell can be started in this environment.")
        }
        if case .failed(let message)? = await observations.outcome(for: shell) {
            throw ExecutionError.modeUnavailable(.unleashed, reason: message)
        }
        return LocalProcessSession(
            executable: shell,
            environment: Self.environment(for: scan, shell: shell),
            workingDirectory: Self.homeDirectory(scan: scan),
            observations: observations,
            gate: gate
        )
    }

    static func homeDirectory(scan: UnleashedEnvironmentScan) -> String? {
        if let home = ProcessInfo.processInfo.environment["HOME"], FileManager.default.fileExists(atPath: home) {
            // Inside an iOS app this is the app container; prefer the mobile user's home when readable.
            if let mobile = scan.locations.first(where: { $0.path == "/var/mobile" && $0.listable }) { return mobile.path }
            return home
        }
        return scan.locations.first(where: { $0.path == "/var/mobile" && $0.listable })?.path
    }

    /// A minimal, explicit environment for spawned shells. Nothing secret is passed.
    static func environment(for scan: UnleashedEnvironmentScan, shell: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": scan.searchPath.joined(separator: ":"),
            "SHELL": shell,
            "HCG_TERMINAL_MODE": "unleashed",
        ]
        if let home = homeDirectory(scan: scan) { environment["HOME"] = home }
        if let user = inherited["USER"] ?? inherited["LOGNAME"] { environment["USER"] = user }
        if let tmp = inherited["TMPDIR"] { environment["TMPDIR"] = tmp }
        return environment
    }
}

// MARK: - Package management

public struct InstalledPackage: Hashable, Sendable, Identifiable {
    public var name: String
    public var version: String
    public var status: String
    public var id: String { name }
}

public enum PackageAction: Hashable, Sendable {
    case install(String)
    case remove(String)
    case refreshIndexes

    public var title: String {
        switch self {
        case .install(let name): "Install \(name)"
        case .remove(let name): "Remove \(name)"
        case .refreshIndexes: "Refresh package lists"
        }
    }
}

public enum PackageManagerError: Error, LocalizedError, Equatable {
    case notAvailable
    case invalidPackageName(String)
    case declined
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable: "No supported package manager was found."
        case .invalidPackageName(let name): "“\(name)” is not a valid package name."
        case .declined: "Not run: authorization was declined."
        case .failed(let message): message
        }
    }
}

/// Interacts with apt/dpkg exactly as installed. Listing is read-only. Changes are never run
/// automatically: `authorizedCommand(for:)` returns a command line only after the user
/// explicitly approves it, and the interface runs it in a visible Local Unleashed session so
/// any password prompt from the tools themselves is shown to the user.
public struct PackageManagerClient: Sendable {
    public let scan: UnleashedEnvironmentScan
    private let gate: AuthorizationGate

    public init(scan: UnleashedEnvironmentScan, gate: AuthorizationGate) {
        self.scan = scan
        self.gate = gate
    }

    public var isAvailable: Bool { !scan.packageManagers.isEmpty }

    private func tool(_ name: String) -> DetectedTool? { scan.packageManagers.first { $0.name == name } }

    public func listInstalled() async throws -> [InstalledPackage] {
        guard let query = tool("dpkg-query") ?? tool("dpkg") else { throw PackageManagerError.notAvailable }
        let arguments = query.name == "dpkg-query"
            ? ["-W", "-f", "${Package}\\t${Version}\\t${db:Status-Abbrev}\\n"]
            : ["-l"]
        let result = try await ProcessRunner.run(
            executable: query.path, arguments: arguments,
            environment: ["PATH": scan.searchPath.joined(separator: ":"), "LANG": "C"]
        )
        guard result.status == 0 else { throw PackageManagerError.failed(result.stderrText.isEmpty ? "exit \(result.status)" : result.stderrText) }
        if query.name == "dpkg-query" {
            return result.stdoutText.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3 else { return nil }
                return InstalledPackage(name: fields[0], version: fields[1], status: fields[2].trimmingCharacters(in: .whitespaces))
            }
        }
        return result.stdoutText.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, fields[0].count == 2 else { return nil }
            return InstalledPackage(name: fields[1], version: fields[2], status: fields[0])
        }
    }

    public static func isValidPackageName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first), name.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-.")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The command line for an action, exactly as it would be typed. No `sudo` is added.
    public func commandLine(for action: PackageAction) throws -> String {
        guard let apt = tool("apt-get") ?? tool("apt") else { throw PackageManagerError.notAvailable }
        switch action {
        case .install(let name), .remove(let name):
            guard Self.isValidPackageName(name) else { throw PackageManagerError.invalidPackageName(name) }
            let verb = if case .install = action { "install" } else { "remove" }
            return "\(apt.path) \(verb) \(name)"
        case .refreshIndexes:
            return "\(apt.path) update"
        }
    }

    /// Asks the user. Returns the command line only if they explicitly approved it.
    public func authorizedCommand(for action: PackageAction) async throws -> String {
        let command = try commandLine(for: action)
        let request = AuthorizationRequest(
            title: action.title,
            commandLine: command,
            target: .local(.unleashed),
            reasons: ["Changes installed packages on this device.", "Runs with the permissions the device grants to this app; apt may refuse without root."]
        )
        guard await gate.requestAuthorization(request) else { throw PackageManagerError.declined }
        await DiagnosticLog.shared.record(.notice, "packages", "Package action authorized", metadata: ["action": action.title])
        return command
    }
}

// MARK: - Permitted locations and logs

public enum LocationBrowserError: Error, LocalizedError, Equatable {
    case notPermitted(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let path): "\(path) is not inside a location this device permits."
        case .unreadable(let path): "\(path) could not be read."
        }
    }
}

public struct HostFileEntry: Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var id: String { path }
}

/// Read-only browsing of locations outside the sandbox that the scan found readable.
public struct PermittedLocationBrowser: Sendable {
    public let roots: [String]

    public init(scan: UnleashedEnvironmentScan) {
        roots = scan.permittedLocations.filter(\.listable).map(\.path)
    }

    public static let logDirectories = ["/var/log", "/private/var/log", "/var/jb/var/log", "/var/mobile/Library/Logs", "/var/mobile/Library/Logs/CrashReporter"]

    func check(_ path: String) throws -> String {
        let standardized = (path as NSString).standardizingPath
        guard roots.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) else {
            throw LocationBrowserError.notPermitted(path)
        }
        return standardized
    }

    public func list(_ path: String) throws -> [HostFileEntry] {
        let directory = try check(path)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            throw LocationBrowserError.unreadable(directory)
        }
        return names.sorted().map { name in
            let full = (directory as NSString).appendingPathComponent(name)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
            return HostFileEntry(
                path: full, name: name,
                isDirectory: (attributes[.type] as? FileAttributeType) == .typeDirectory,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attributes[.modificationDate] as? Date
            )
        }
    }

    /// Reads at most `maxBytes` from the end of a file (log inspection).
    public func readTail(_ path: String, maxBytes: Int = 256 * 1024) throws -> String {
        let file = try check(path)
        guard let handle = FileHandle(forReadingAtPath: file) else { throw LocationBrowserError.unreadable(file) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Log directories among the permitted roots.
    public var logRoots: [String] {
        Self.logDirectories.filter { candidate in roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") } }
    }
}
