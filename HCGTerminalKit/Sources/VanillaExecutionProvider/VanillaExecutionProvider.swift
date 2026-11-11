import Diagnostics
import FileWorkspace
import Foundation
import LocalCommandEngine
import TerminalCapabilityProvider
import TerminalCore

/// Capability report for the standard iOS/iPadOS environment.
///
/// Vanilla never probes outside the app container except for one read-only process-table
/// count, and never attempts process execution or private APIs.
public struct VanillaCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .vanilla
    private let workspace: FileWorkspace
    private let probe: any SystemProbing

    public init(workspace: FileWorkspace, probe: any SystemProbing = LiveSystemProbe()) {
        self.workspace = workspace
        self.probe = probe
    }

    public func detectCapabilities() async -> CapabilityReport {
        let builtinCount = BuiltinRegistry.standard.commands.count
        let rootPath = workspace.rootURL.path
        let writable = probe.isWritable(rootPath)
        let processCount = probe.visibleProcessCount()

        let results: [CapabilityResult] = [
            CapabilityResult(
                kind: .localShell,
                availability: .limited("HCG Terminal's built-in command environment. iOS does not allow App Store apps to start a system shell."),
                summary: "\(builtinCount) built-in commands with pipes, redirection and history.",
                evidence: [CapabilityEvidence(probe: "Built-in command registry", observation: "\(builtinCount) commands", positive: true)]
            ),
            CapabilityResult(
                kind: .executableAccess,
                availability: .unavailable("Running other executables is not permitted in the iOS app sandbox. Use a remote host for system tools."),
                summary: "Only built-in commands run locally.",
                evidence: [CapabilityEvidence(probe: "Vanilla policy", observation: "no local process execution", positive: false)]
            ),
            CapabilityResult(
                kind: .filesystemPermissions,
                availability: writable ? .limited("App sandbox workspace only.") : .unavailable("The app workspace is not writable."),
                summary: "Read and write inside the app's workspace (also visible in the Files app).",
                evidence: [CapabilityEvidence(probe: "access(workspace, W_OK)", observation: writable ? "writable" : "not writable", positive: writable)]
            ),
            CapabilityResult(
                kind: .packageManager,
                availability: .unavailable("Package managers are not available in Vanilla."),
                summary: "Install toolchains on a remote host instead."
            ),
            processInspectionResult(processCount),
            CapabilityResult(
                kind: .privilegedOperations,
                availability: .unavailable("Vanilla never performs privileged operations."),
                summary: "Everything runs with the app's ordinary sandbox permissions."
            ),
            SharedCapabilities.remoteSSH(),
            SharedCapabilities.buildOrchestration(),
        ]
        return CapabilityReport(
            mode: .vanilla,
            results: results,
            localFeaturesAvailable: true,
            headline: "Vanilla terminal and remote development are available.",
            buildNotes: []
        )
    }

    private func processInspectionResult(_ count: Int?) -> CapabilityResult {
        let evidence = CapabilityEvidence(
            probe: "sysctl(KERN_PROC_ALL)",
            observation: count.map { "\($0) process(es) visible" } ?? "not permitted",
            positive: (count ?? 0) > 1
        )
        switch count {
        case .some(let n) where n > 1:
            return CapabilityResult(kind: .processInspection, availability: .limited("Read-only list of \(n) processes the system reveals to this app."), summary: "Read-only process list.", evidence: [evidence])
        default:
            return CapabilityResult(kind: .processInspection, availability: .unavailable("The sandbox reveals only this app's own process."), summary: "System process list is not visible.", evidence: [evidence])
        }
    }
}

/// Creates Local Vanilla sessions: built-in commands on the app workspace. Commands that are
/// not built-ins are refused with an explanation — never executed elsewhere.
public struct VanillaExecutionProvider: LocalExecutionProvider {
    public let mode: ExecutionMode = .vanilla
    private let workspace: FileWorkspace
    private let capabilities: VanillaCapabilityProvider

    public init(workspace: FileWorkspace, capabilities: VanillaCapabilityProvider) {
        self.workspace = workspace
        self.capabilities = capabilities
    }

    public func availableBackend() async -> SessionBackend? { .builtInCommands }

    public func makeSession() async throws -> any TerminalSession {
        let capabilities = self.capabilities
        let session = BuiltinShellSession(
            configuration: BuiltinShellConfiguration(
                target: .local(.vanilla),
                workspace: workspace,
                environment: ["USER": "mobile", "SHELL": "hcg-builtin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
                banner: Self.banner,
                promptLabel: "vanilla",
                promptColor: ANSI.cyan,
                sessionDescription: [
                    "Target:   Local Vanilla (this device, app sandbox)",
                    "Backend:  \(SessionBackend.builtInCommands.label)",
                    "Mode:     Vanilla",
                ],
                capabilityDescription: { CapabilityReportFormatter.text(await capabilities.detectCapabilities()) }
            ),
            external: RefusingExternalCommandHandler(
                policyDescription: "Vanilla runs built-in commands only. Other programs are not executed on this device and are never sent to a remote host automatically; open a Remote Host session for system tools.",
                explanation: "Vanilla runs built-in commands only (type `help`). For system tools, open a Remote Host session."
            )
        )
        await session.refreshCapabilityDescription()
        await DiagnosticLog.shared.record(.info, "session", "Opened Local Vanilla session", metadata: ["session": session.id.description])
        return session
    }

    static let banner = """
    \(ANSI.cyan)HCG Terminal\(ANSI.reset) · \(ANSI.bold)Local Vanilla\(ANSI.reset)
    Built-in commands on the app workspace. Type \(ANSI.bold)help\(ANSI.reset) for the list.
    Remote hosts run in their own sessions; nothing typed here is sent anywhere else.

    """
}
