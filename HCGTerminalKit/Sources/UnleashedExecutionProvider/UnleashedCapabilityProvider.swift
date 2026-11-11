import Foundation
import TerminalCapabilityProvider
import TerminalCore

/// Capability report for Unleashed, built from the read-only scan plus runtime observations.
public struct UnleashedCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .unleashed
    private let scanner: UnleashedEnvironmentScanner
    private let observations: RuntimeObservations

    public init(probe: any SystemProbing = LiveSystemProbe(), observations: RuntimeObservations) {
        self.scanner = UnleashedEnvironmentScanner(probe: probe)
        self.observations = observations
    }

    public func scan() -> UnleashedEnvironmentScan { scanner.scan() }

    public func detectCapabilities() async -> CapabilityReport {
        let scan = scanner.scan()
        return await Self.report(for: scan, observations: observations)
    }

    public static func report(for scan: UnleashedEnvironmentScan, observations: RuntimeObservations) async -> CapabilityReport {
        // Local shell
        var shellOutcome: RuntimeObservations.SpawnOutcome?
        if let shell = scan.shells.first { shellOutcome = await observations.outcome(for: shell) }
        let shellResult: CapabilityResult
        let shellEvidence = scan.evidence.filter { $0.probe.contains("X_OK") || $0.probe.contains("127.0.0.1") }
        if let shell = scan.shells.first {
            switch shellOutcome {
            case .succeeded(let pid)?:
                shellResult = CapabilityResult(kind: .localShell, availability: .available, summary: "\(shell) runs in a local pseudo-terminal (verified, pid \(pid)).", evidence: shellEvidence)
            case .failed(let message)? where !scan.loopbackServicePorts.isEmpty:
                shellResult = CapabilityResult(kind: .localShell, availability: .limited("\(shell) could not be started (\(message)), but a terminal service accepts connections on 127.0.0.1:\(scan.loopbackServicePorts[0])."), summary: "Existing local terminal service.", evidence: shellEvidence)
            case .failed(let message)?:
                shellResult = CapabilityResult(kind: .localShell, availability: .unavailable("\(shell) exists but could not be started: \(message)"), summary: "The device refused to start the shell.", evidence: shellEvidence)
            case nil:
                shellResult = CapabilityResult(kind: .localShell, availability: .unverified("\(shell) is present and executable. Starting it is verified when you open a Local Unleashed session."), summary: "Local shell detected.", evidence: shellEvidence)
            }
        } else if let port = scan.loopbackServicePorts.first {
            shellResult = CapabilityResult(kind: .localShell, availability: .limited("No shell can be started directly, but a terminal service accepts connections on 127.0.0.1:\(port). Signing in uses that service's own credentials."), summary: "Existing local terminal service.", evidence: shellEvidence)
        } else {
            shellResult = CapabilityResult(kind: .localShell, availability: .unavailable("No executable shell and no local terminal service were found."), summary: "No local shell.", evidence: shellEvidence)
        }

        // Executable access
        let executableCount = scan.executableDirectories.values.reduce(0, +)
        let executableEvidence = scan.evidence.filter { $0.probe.hasPrefix("list ") }
        let spawnRefuted: Bool = { if case .failed? = shellOutcome { true } else { false } }()
        let executableResult: CapabilityResult
        if executableCount == 0 {
            executableResult = CapabilityResult(kind: .executableAccess, availability: .unavailable("No executable directories are visible to this app."), summary: "No additional command-line tools.", evidence: executableEvidence)
        } else if spawnRefuted {
            executableResult = CapabilityResult(kind: .executableAccess, availability: .unavailable("\(executableCount) tools are visible, but the device does not allow this app to start processes."), summary: "Tools visible but not executable from this app.", evidence: executableEvidence)
        } else if await observations.anySucceeded() {
            executableResult = CapabilityResult(kind: .executableAccess, availability: .available, summary: "\(executableCount) executables in \(scan.executableDirectories.keys.sorted().joined(separator: ", ")).", evidence: executableEvidence)
        } else {
            executableResult = CapabilityResult(kind: .executableAccess, availability: .unverified("\(executableCount) executables visible. Execution is verified on first use."), summary: "Installed command-line tools detected.", evidence: executableEvidence)
        }

        // Filesystem
        let permitted = scan.permittedLocations
        let readable = permitted.filter(\.readable).map(\.path)
        let writable = permitted.filter(\.writable).map(\.path)
        let fsEvidence = scan.locations.map {
            CapabilityEvidence(probe: "access(\($0.path))", observation: $0.exists ? "r=\($0.readable) list=\($0.listable) w=\($0.writable)" : "absent or not visible", positive: $0.readable)
        }
        let filesystemResult = permitted.isEmpty
            ? CapabilityResult(kind: .filesystemPermissions, availability: .unavailable("No location outside the app sandbox is accessible."), summary: "Sandbox only.", evidence: fsEvidence)
            : CapabilityResult(
                kind: .filesystemPermissions,
                availability: .limited("Readable: \(readable.joined(separator: ", ")). Writable: \(writable.isEmpty ? "none" : writable.joined(separator: ", "))."),
                summary: "Access exactly as the device permits; nothing is remounted or re-permissioned.",
                evidence: fsEvidence
            )

        // Package manager
        let packageEvidence = scan.packageManagers.map { CapabilityEvidence(probe: "access(\($0.path), X_OK)", observation: "executable", positive: true) }
        let packageResult = scan.packageManagers.isEmpty
            ? CapabilityResult(kind: .packageManager, availability: .unavailable("No supported package manager (apt, dpkg) was found."), summary: "No package manager.")
            : CapabilityResult(
                kind: .packageManager,
                availability: .requiresAuthorization("\(scan.packageManagers.map(\.name).joined(separator: ", ")) found. Listing packages is read-only; installing or removing needs your explicit approval each time and runs with the permissions the device grants."),
                summary: "Package management through the installed tools.",
                evidence: packageEvidence
            )

        // Process inspection
        let processEvidence = scan.evidence.filter { $0.probe.hasPrefix("sysctl") }
        let processResult: CapabilityResult
        switch scan.visibleProcessCount {
        case .some(let count) where count > 1:
            processResult = CapabilityResult(kind: .processInspection, availability: .available, summary: "\(count) processes visible (read-only).", evidence: processEvidence)
        default:
            processResult = CapabilityResult(kind: .processInspection, availability: .unavailable("The system reveals only this app's own process."), summary: "Process list not visible.", evidence: processEvidence)
        }

        // Privileged operations
        let privilegeEvidence = scan.evidence.filter { $0.probe == "geteuid()" }
            + scan.elevationTools.map { CapabilityEvidence(probe: "access(\($0.path), X_OK)", observation: "executable", positive: true) }
        let privilegedResult: CapabilityResult
        if scan.effectiveUserID == 0 {
            privilegedResult = CapabilityResult(kind: .privilegedOperations, availability: .requiresAuthorization("This app process already runs as root (euid 0). Privileged commands still need your explicit approval each time."), summary: "Running as root.", evidence: privilegeEvidence)
        } else if let tool = scan.elevationTools.first {
            privilegedResult = CapabilityResult(kind: .privilegedOperations, availability: .requiresAuthorization("\(tool.name) found at \(tool.path). HCG Terminal never runs it on its own; it asks for its own password, which HCG Terminal does not store. Commands run as uid \(scan.effectiveUserID) otherwise."), summary: "Elevation only through tools you invoke.", evidence: privilegeEvidence)
        } else {
            privilegedResult = CapabilityResult(kind: .privilegedOperations, availability: .unavailable("No elevation mechanism detected. Commands run as uid \(scan.effectiveUserID)."), summary: "No privileged operations.", evidence: privilegeEvidence)
        }

        let localAvailable = shellResult.availability.isUsable
        return CapabilityReport(
            mode: .unleashed,
            results: [
                shellResult, executableResult, filesystemResult, packageResult, processResult, privilegedResult,
                SharedCapabilities.remoteSSH(), SharedCapabilities.buildOrchestration(),
            ],
            localFeaturesAvailable: localAvailable,
            headline: localAvailable
                ? "Unleashed features are available as listed. Nothing is installed or elevated automatically."
                : CapabilityReport.unleashedUnavailableMessage,
            buildNotes: ["Unleashed build. \(scan.operatingSystem)"]
        )
    }
}
