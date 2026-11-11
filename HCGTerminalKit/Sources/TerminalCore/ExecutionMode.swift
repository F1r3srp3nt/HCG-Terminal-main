import Foundation

/// The two user-selectable local execution modes.
///
/// User-facing names are always "Vanilla" and "Unleashed". Technical documentation may
/// describe Unleashed as the backend for supported jailbroken devices; the interface does not.
public enum ExecutionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Standard, sandboxed iOS/iPadOS environment.
    case vanilla
    /// Optional advanced environment, only where the device actually grants the capabilities.
    case unleashed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vanilla: "Vanilla"
        case .unleashed: "Unleashed"
        }
    }

    public var summary: String {
        switch self {
        case .vanilla:
            "Sandboxed local workspace with built-in commands. Remote SSH development is always available."
        case .unleashed:
            "Uses local shells, tools and locations the device actually permits. Nothing is installed or elevated automatically."
        }
    }

    /// SF Symbol used by the mode selector.
    public var symbolName: String {
        switch self {
        case .vanilla: "shield.lefthalf.filled"
        case .unleashed: "bolt.horizontal.circle"
        }
    }
}

/// A remote machine reached over SSH. Value type so it can be shown and compared without
/// holding a live connection.
public struct RemoteEndpoint: Hashable, Codable, Sendable {
    public var hostID: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String

    public init(hostID: UUID, displayName: String, hostname: String, port: Int = 22, username: String) {
        self.hostID = hostID
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
    }

    /// `user@host` or `user@host:port` when the port is not 22.
    public var address: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

/// Where the commands of a session execute. Every session has exactly one target for its
/// whole life; nothing in HCG Terminal moves a session to another target implicitly.
public enum ExecutionTarget: Hashable, Codable, Sendable {
    case local(ExecutionMode)
    case remote(RemoteEndpoint)

    /// The three labels the interface uses: "Local Vanilla", "Local Unleashed", "Remote Host".
    public var label: String {
        switch self {
        case .local(.vanilla): "Local Vanilla"
        case .local(.unleashed): "Local Unleashed"
        case .remote: "Remote Host"
        }
    }

    /// Secondary line, for example `ana@build-mac.local`.
    public var detail: String {
        switch self {
        case .local(.vanilla): "This device · app sandbox"
        case .local(.unleashed): "This device · permitted local environment"
        case .remote(let endpoint): endpoint.address
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    public var localMode: ExecutionMode? {
        if case .local(let mode) = self { return mode }
        return nil
    }

    public var remoteEndpoint: RemoteEndpoint? {
        if case .remote(let endpoint) = self { return endpoint }
        return nil
    }
}
