import FileWorkspace
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
import TerminalUI
import UnleashedExecutionProvider

/// Composition for the Unleashed app target. Linked only by that target, so the standard
/// build contains no Unleashed code at all.
public enum UnleashedIntegration {
    public static func dependencies(
        workspace: FileWorkspace,
        supportDirectory: URL,
        credentials: any CredentialStore = DefaultCredentialStore.make(),
        preferences: ModePreferenceStore = ModePreferenceStore()
    ) -> AppDependencies {
        var dependencies = AppDependencies.standard(
            workspace: workspace, supportDirectory: supportDirectory, credentials: credentials, preferences: preferences
        )
        let observations = RuntimeObservations()
        let capabilities = UnleashedCapabilityProvider(observations: observations)
        dependencies.distribution = .unleashed
        dependencies.unleashedCapabilities = capabilities
        dependencies.unleashed = UnleashedExecutionProvider(capabilities: capabilities, observations: observations, gate: dependencies.gate)
        dependencies.unleashedTools = UnleashedToolsAdapter(capabilities: capabilities, gate: dependencies.gate)
        return dependencies
    }
}

/// Bridges the Unleashed module to the interface's `UnleashedTools` protocol.
actor UnleashedToolsAdapter: UnleashedTools {
    private let capabilities: UnleashedCapabilityProvider
    private let gate: AuthorizationGate
    private var cachedScan: (UnleashedEnvironmentScan, Date)?

    init(capabilities: UnleashedCapabilityProvider, gate: AuthorizationGate) {
        self.capabilities = capabilities
        self.gate = gate
    }

    /// Read-only scan, cached briefly so one screen does not rescan repeatedly.
    private func scan() -> UnleashedEnvironmentScan {
        if let (scan, date) = cachedScan, Date().timeIntervalSince(date) < 10 { return scan }
        let scan = capabilities.scan()
        cachedScan = (scan, Date())
        return scan
    }

    func loopbackServicePorts() async -> [Int] { scan().loopbackServicePorts }

    func packageManagerAvailable() async -> Bool { !scan().packageManagers.isEmpty }

    func installedPackages() async throws -> [PackageRow] {
        try await PackageManagerClient(scan: scan(), gate: gate).listInstalled()
            .map { PackageRow(name: $0.name, version: $0.version, status: $0.status) }
    }

    func authorizedPackageCommand(_ request: PackageRequest) async throws -> String {
        let action: PackageAction = switch request {
        case .install(let name): .install(name)
        case .remove(let name): .remove(name)
        case .refreshIndexes: .refreshIndexes
        }
        return try await PackageManagerClient(scan: scan(), gate: gate).authorizedCommand(for: action)
    }

    func permittedRoots() async -> [String] { PermittedLocationBrowser(scan: scan()).roots }

    func logRoots() async -> [String] { PermittedLocationBrowser(scan: scan()).logRoots }

    func list(_ path: String) async throws -> [HostFileRow] {
        try PermittedLocationBrowser(scan: scan()).list(path)
            .map { HostFileRow(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, size: $0.size) }
    }

    func readTail(_ path: String) async throws -> String {
        try PermittedLocationBrowser(scan: scan()).readTail(path)
    }
}
