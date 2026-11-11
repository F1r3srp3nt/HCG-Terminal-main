import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import FileWorkspace
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
import VanillaExecutionProvider

/// Which app build is running. Decided at compile time by the app target.
public enum DistributionBuild: String, Sendable {
    /// Standard build for ordinary iOS/iPadOS distribution. Does not link the Unleashed backend.
    case standard
    /// Separate Unleashed build for supported devices. Not assumed to be App Store eligible.
    case unleashed

    public var label: String {
        switch self {
        case .standard: "Standard build"
        case .unleashed: "Unleashed build"
        }
    }
}

/// Rows the interface shows for the Unleashed tools. Defined here (not in the Unleashed
/// module) so TerminalUI never links jailbreak-specific code.
public struct PackageRow: Hashable, Sendable, Identifiable {
    public var name: String
    public var version: String
    public var status: String
    public var id: String { name }
    public init(name: String, version: String, status: String) {
        self.name = name
        self.version = version
        self.status = status
    }
}

public struct HostFileRow: Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var id: String { path }
    public init(path: String, name: String, isDirectory: Bool, size: Int64) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

public enum PackageRequest: Hashable, Sendable {
    case install(String)
    case remove(String)
    case refreshIndexes
}

/// Unleashed-only tools, implemented by an adapter in the Unleashed app target.
public protocol UnleashedTools: Sendable {
    func loopbackServicePorts() async -> [Int]
    func packageManagerAvailable() async -> Bool
    func installedPackages() async throws -> [PackageRow]
    /// Returns the exact command line after the user explicitly approved it; throws otherwise.
    func authorizedPackageCommand(_ request: PackageRequest) async throws -> String
    func permittedRoots() async -> [String]
    func logRoots() async -> [String]
    func list(_ path: String) async throws -> [HostFileRow]
    func readTail(_ path: String) async throws -> String
}

/// Everything the interface needs, assembled by the app target's composition root.
public struct AppDependencies: Sendable {
    public var distribution: DistributionBuild
    public var workspace: FileWorkspace
    public var vanilla: any LocalExecutionProvider
    public var vanillaCapabilities: any TerminalCapabilityProvider
    /// `nil` in the standard build.
    public var unleashed: (any LocalExecutionProvider)?
    public var unleashedCapabilities: any TerminalCapabilityProvider
    public var unleashedTools: (any UnleashedTools)?
    public var gate: AuthorizationGate
    public var credentials: any CredentialStore
    public var knownHosts: KnownHostsStore
    public var keyManager: SSHKeyManager
    public var hostStore: HostProfileStore
    public var orchestrator: BuildOrchestrator
    public var artifactIndex: ArtifactIndex
    public var preferences: ModePreferenceStore

    public init(
        distribution: DistributionBuild, workspace: FileWorkspace, vanilla: any LocalExecutionProvider,
        vanillaCapabilities: any TerminalCapabilityProvider, unleashed: (any LocalExecutionProvider)?,
        unleashedCapabilities: any TerminalCapabilityProvider, unleashedTools: (any UnleashedTools)?,
        gate: AuthorizationGate, credentials: any CredentialStore, knownHosts: KnownHostsStore,
        keyManager: SSHKeyManager, hostStore: HostProfileStore, orchestrator: BuildOrchestrator,
        artifactIndex: ArtifactIndex, preferences: ModePreferenceStore
    ) {
        self.distribution = distribution
        self.workspace = workspace
        self.vanilla = vanilla
        self.vanillaCapabilities = vanillaCapabilities
        self.unleashed = unleashed
        self.unleashedCapabilities = unleashedCapabilities
        self.unleashedTools = unleashedTools
        self.gate = gate
        self.credentials = credentials
        self.knownHosts = knownHosts
        self.keyManager = keyManager
        self.hostStore = hostStore
        self.orchestrator = orchestrator
        self.artifactIndex = artifactIndex
        self.preferences = preferences
    }

    /// Standard (Vanilla) composition. The Unleashed build replaces `unleashed`,
    /// `unleashedCapabilities` and `unleashedTools`.
    public static func standard(
        workspace: FileWorkspace,
        supportDirectory: URL,
        credentials: any CredentialStore = DefaultCredentialStore.make(),
        preferences: ModePreferenceStore = ModePreferenceStore()
    ) -> AppDependencies {
        let vanillaCapabilities = VanillaCapabilityProvider(workspace: workspace)
        return AppDependencies(
            distribution: .standard,
            workspace: workspace,
            vanilla: VanillaExecutionProvider(workspace: workspace, capabilities: vanillaCapabilities),
            vanillaCapabilities: vanillaCapabilities,
            unleashed: nil,
            unleashedCapabilities: UnleashedNotIncludedCapabilityProvider(),
            unleashedTools: nil,
            gate: AuthorizationGate(),
            credentials: credentials,
            knownHosts: KnownHostsStore(fileURL: supportDirectory.appendingPathComponent("known_hosts.json")),
            keyManager: SSHKeyManager(credentials: credentials, metadataURL: supportDirectory.appendingPathComponent("ssh-keys.json")),
            hostStore: HostProfileStore(fileURL: supportDirectory.appendingPathComponent("hosts.json")),
            orchestrator: BuildOrchestrator(logDirectory: (try? workspace.url(for: .logs)) ?? supportDirectory.appendingPathComponent("logs")),
            artifactIndex: ArtifactIndex(workspace: workspace),
            preferences: preferences
        )
    }
}

/// Persists the preferred local mode. Only a UI preference; never a capability claim.
public final class ModePreferenceStore: @unchecked Sendable {
    public static let key = "hcg.terminal.preferredLocalMode"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var preferredMode: ExecutionMode {
        get { defaults.string(forKey: Self.key).flatMap(ExecutionMode.init(rawValue:)) ?? .vanilla }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
