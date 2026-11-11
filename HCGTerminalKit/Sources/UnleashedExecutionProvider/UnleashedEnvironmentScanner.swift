import Foundation
import TerminalCapabilityProvider
import TerminalCore

/// Access observed for one filesystem location.
public struct LocationAccess: Hashable, Sendable, Codable {
    public var path: String
    public var exists: Bool
    public var readable: Bool
    public var listable: Bool
    public var writable: Bool
}

public struct DetectedTool: Hashable, Sendable, Codable {
    public var name: String
    public var path: String
}

/// Everything the read-only scan observed. No field is inferred from another: each one
/// comes from its own probe, and each probe is recorded as evidence.
public struct UnleashedEnvironmentScan: Hashable, Sendable {
    /// `/var/jb` for a rootless layout, `""` when tools live at the system root, `nil` if none.
    public var environmentPrefix: String?
    public var shells: [String]
    public var executableDirectories: [String: Int]
    public var packageManagers: [DetectedTool]
    public var elevationTools: [DetectedTool]
    public var effectiveUserID: UInt32
    public var loopbackServicePorts: [Int]
    public var visibleProcessCount: Int?
    public var locations: [LocationAccess]
    public var evidence: [CapabilityEvidence]
    public var operatingSystem: String

    public var permittedLocations: [LocationAccess] { locations.filter { $0.readable || $0.writable } }

    /// Directories to put on PATH for spawned shells, in priority order.
    public var searchPath: [String] {
        let prefix = environmentPrefix ?? ""
        var paths = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"].map { prefix + $0 }
        if !prefix.isEmpty { paths += ["/usr/sbin", "/usr/bin", "/sbin", "/bin"] }
        var unique: [String] = []
        for path in paths where !unique.contains(path) { unique.append(path) }
        return unique
    }
}

/// Performs the read-only Unleashed scan. Uses only `SystemProbing` (stat, access, directory
/// listing, a sysctl read and loopback TCP connects without sending data).
public struct UnleashedEnvironmentScanner: Sendable {
    public static let prefixes = ["/var/jb", ""]
    public static let shellCandidates = ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh", "/bin/dash"]
    public static let binDirectories = ["/usr/bin", "/bin", "/usr/local/bin", "/usr/sbin", "/sbin"]
    public static let packageManagerCandidates = [("apt", "/usr/bin/apt"), ("apt-get", "/usr/bin/apt-get"), ("dpkg", "/usr/bin/dpkg"), ("dpkg-query", "/usr/bin/dpkg-query")]
    public static let elevationCandidates = [("sudo", "/usr/bin/sudo"), ("su", "/usr/bin/su"), ("su", "/bin/su")]
    public static let loopbackPorts = [22, 2222]
    public static let locationCandidates = [
        "/var/mobile", "/var/mobile/Documents", "/var/mobile/Library/Logs", "/var/jb", "/var/jb/etc",
        "/var/jb/var/log", "/var/log", "/private/var/tmp", "/tmp", "/etc", "/Applications",
        "/var/containers/Bundle/Application",
    ]

    private let probe: any SystemProbing

    public init(probe: any SystemProbing) {
        self.probe = probe
    }

    public func scan() -> UnleashedEnvironmentScan {
        var evidence: [CapabilityEvidence] = []

        // Layout indicator (context only — never decisive on its own).
        let rootlessPrefix = probe.isDirectory("/var/jb")
        evidence.append(CapabilityEvidence(probe: "stat(/var/jb)", observation: rootlessPrefix ? "directory" : "absent or not visible", positive: rootlessPrefix))

        var shells: [String] = []
        var directories: [String: Int] = [:]
        var packageManagers: [DetectedTool] = []
        var elevation: [DetectedTool] = []
        var prefixWithTools: String?

        for prefix in Self.prefixes {
            for candidate in Self.shellCandidates {
                let path = prefix + candidate
                guard !shells.contains(path) else { continue }
                if probe.isExecutableFile(path) {
                    shells.append(path)
                    if prefixWithTools == nil { prefixWithTools = prefix }
                    evidence.append(CapabilityEvidence(probe: "access(\(path), X_OK)", observation: "executable", positive: true))
                }
            }
            for directory in Self.binDirectories {
                let path = prefix + directory
                guard directories[path] == nil, let entries = probe.listDirectory(path) else { continue }
                let executables = entries.prefix(4000).filter { probe.isExecutableFile(path + "/" + $0) }.count
                if executables > 0 {
                    directories[path] = executables
                    evidence.append(CapabilityEvidence(probe: "list \(path)", observation: "\(executables) executables", positive: true))
                }
            }
            for (name, candidate) in Self.packageManagerCandidates where probe.isExecutableFile(prefix + candidate) {
                if !packageManagers.contains(where: { $0.path == prefix + candidate }) {
                    packageManagers.append(DetectedTool(name: name, path: prefix + candidate))
                    evidence.append(CapabilityEvidence(probe: "access(\(prefix + candidate), X_OK)", observation: "executable", positive: true))
                }
            }
            for (name, candidate) in Self.elevationCandidates where probe.isExecutableFile(prefix + candidate) {
                if !elevation.contains(where: { $0.path == prefix + candidate }) {
                    elevation.append(DetectedTool(name: name, path: prefix + candidate))
                }
            }
        }
        if shells.isEmpty {
            evidence.append(CapabilityEvidence(probe: "access(<shell candidates>, X_OK)", observation: "no executable shell visible", positive: false))
        }

        let ports = Self.loopbackPorts.filter { probe.loopbackPortAccepts($0, timeout: 0.3) }
        for port in Self.loopbackPorts {
            let accepted = ports.contains(port)
            evidence.append(CapabilityEvidence(probe: "TCP connect 127.0.0.1:\(port) (no data sent)", observation: accepted ? "accepted" : "refused or filtered", positive: accepted))
        }

        let processCount = probe.visibleProcessCount()
        evidence.append(CapabilityEvidence(probe: "sysctl(KERN_PROC_ALL)", observation: processCount.map { "\($0) visible" } ?? "not permitted", positive: (processCount ?? 0) > 1))

        let euid = probe.effectiveUserID()
        evidence.append(CapabilityEvidence(probe: "geteuid()", observation: "\(euid)", positive: euid == 0))

        let locations = Self.locationCandidates.map { path -> LocationAccess in
            let exists = probe.exists(path)
            return LocationAccess(
                path: path,
                exists: exists,
                readable: exists && probe.isReadable(path),
                listable: exists && probe.listDirectory(path) != nil,
                writable: exists && probe.isWritable(path)
            )
        }

        return UnleashedEnvironmentScan(
            environmentPrefix: prefixWithTools ?? (rootlessPrefix ? "/var/jb" : nil),
            shells: shells,
            executableDirectories: directories,
            packageManagers: packageManagers,
            elevationTools: elevation,
            effectiveUserID: euid,
            loopbackServicePorts: ports,
            visibleProcessCount: processCount,
            locations: locations,
            evidence: evidence,
            operatingSystem: probe.osDescription()
        )
    }
}

/// Outcomes observed when the user actually used a capability. Detection never executes
/// anything; these observations let the report move from "detected" to "verified" (or to
/// "unavailable" with the real error) after explicit use.
public actor RuntimeObservations {
    public enum SpawnOutcome: Hashable, Sendable {
        case succeeded(pid: Int32)
        case failed(String)
    }

    private var spawns: [String: SpawnOutcome] = [:]

    public init() {}

    public func record(executable: String, outcome: SpawnOutcome) {
        spawns[executable] = outcome
    }

    public func outcome(for executable: String) -> SpawnOutcome? { spawns[executable] }

    public func anySucceeded() -> Bool {
        spawns.values.contains { if case .succeeded = $0 { true } else { false } }
    }
}
