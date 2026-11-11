import Foundation
import TerminalCore

/// The capability areas every provider must report on.
public enum CapabilityKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case localShell
    case executableAccess
    case filesystemPermissions
    case packageManager
    case processInspection
    case privilegedOperations
    case remoteSSH
    case buildOrchestration

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localShell: "Local shell"
        case .executableAccess: "Executable access"
        case .filesystemPermissions: "Filesystem permissions"
        case .packageManager: "Package manager"
        case .processInspection: "Process inspection"
        case .privilegedOperations: "Privileged operations"
        case .remoteSSH: "Remote SSH"
        case .buildOrchestration: "Build and test orchestration"
        }
    }

    public var symbolName: String {
        switch self {
        case .localShell: "terminal"
        case .executableAccess: "gearshape.2"
        case .filesystemPermissions: "folder.badge.gearshape"
        case .packageManager: "shippingbox"
        case .processInspection: "list.bullet.rectangle"
        case .privilegedOperations: "lock.shield"
        case .remoteSSH: "network"
        case .buildOrchestration: "hammer"
        }
    }
}

/// Availability of one capability. Never optimistic: anything not positively observed is
/// reported as unavailable or unverified.
public enum CapabilityAvailability: Hashable, Codable, Sendable {
    /// Observed working (or structurally guaranteed, e.g. built-in commands).
    case available
    /// Partially available; `detail` says what is and is not possible.
    case limited(String)
    /// Indicators were found but the capability has not been exercised yet. It will be
    /// confirmed or refuted the first time the user explicitly uses it.
    case unverified(String)
    /// Exists, but every use needs explicit user authorization and runs with the permissions
    /// the device actually grants.
    case requiresAuthorization(String)
    case unavailable(String)

    public var isUsable: Bool {
        switch self {
        case .available, .limited, .unverified, .requiresAuthorization: true
        case .unavailable: false
        }
    }

    public var label: String {
        switch self {
        case .available: "Available"
        case .limited: "Limited"
        case .unverified: "Detected, not yet verified"
        case .requiresAuthorization: "Requires authorization"
        case .unavailable: "Unavailable"
        }
    }

    public var detail: String? {
        switch self {
        case .available: nil
        case .limited(let s), .unverified(let s), .requiresAuthorization(let s), .unavailable(let s): s
        }
    }
}

/// A single read-only observation that contributed to a result.
public struct CapabilityEvidence: Hashable, Codable, Sendable {
    /// What was checked, e.g. `access("/var/jb/bin/sh", X_OK)`.
    public var probe: String
    /// What was observed, e.g. `executable`.
    public var observation: String
    /// Whether this observation supports the capability being present.
    public var positive: Bool

    public init(probe: String, observation: String, positive: Bool) {
        self.probe = probe
        self.observation = observation
        self.positive = positive
    }
}

public struct CapabilityResult: Hashable, Codable, Sendable, Identifiable {
    public var kind: CapabilityKind
    public var availability: CapabilityAvailability
    public var summary: String
    public var evidence: [CapabilityEvidence]

    public var id: CapabilityKind { kind }

    public init(kind: CapabilityKind, availability: CapabilityAvailability, summary: String, evidence: [CapabilityEvidence] = []) {
        self.kind = kind
        self.availability = availability
        self.summary = summary
        self.evidence = evidence
    }
}

/// A complete, timestamped capability report for one mode.
public struct CapabilityReport: Hashable, Codable, Sendable {
    public var mode: ExecutionMode
    public var generatedAt: Date
    public var results: [CapabilityResult]
    /// Overall verdict for the mode's *local* features. For Vanilla this is always true.
    public var localFeaturesAvailable: Bool
    /// Short explanation of the overall verdict.
    public var headline: String
    /// Build-level facts, e.g. "Standard distribution build".
    public var buildNotes: [String]

    public init(
        mode: ExecutionMode,
        generatedAt: Date = Date(),
        results: [CapabilityResult],
        localFeaturesAvailable: Bool,
        headline: String,
        buildNotes: [String] = []
    ) {
        self.mode = mode
        self.generatedAt = generatedAt
        // Always present all kinds, in canonical order.
        self.results = CapabilityKind.allCases.map { kind in
            results.first(where: { $0.kind == kind })
                ?? CapabilityResult(kind: kind, availability: .unavailable("Not reported."), summary: "Not reported by this provider.")
        }
        self.localFeaturesAvailable = localFeaturesAvailable
        self.headline = headline
        self.buildNotes = buildNotes
    }

    public subscript(kind: CapabilityKind) -> CapabilityResult {
        results.first(where: { $0.kind == kind })!
    }

    /// The exact message the interface shows when Unleashed features are unavailable.
    public static let unleashedUnavailableMessage =
        "Unleashed features are not available in this environment. Vanilla terminal and remote development remain available."
}

/// The interface implemented separately by the Vanilla and Unleashed providers.
///
/// Contract:
/// - Detection is read-only. It may stat files, call `access(2)`, list directories, read
///   sysctl values and open a TCP connection to the loopback interface without authenticating.
///   It never writes, spawns processes, loads code, requests privileges or changes settings.
/// - No single indicator decides a result; results carry the evidence used.
/// - Capabilities are never simulated. Anything not observed is reported as unavailable or
///   unverified.
public protocol TerminalCapabilityProvider: Sendable {
    var mode: ExecutionMode { get }
    func detectCapabilities() async -> CapabilityReport
}

/// Shared results for capabilities that do not depend on the local mode.
public enum SharedCapabilities {
    public static func remoteSSH() -> CapabilityResult {
        CapabilityResult(
            kind: .remoteSSH,
            availability: .available,
            summary: "SSH connections with interactive PTY sessions. Independent of the local mode.",
            evidence: [CapabilityEvidence(probe: "RemoteSSH module linked", observation: "SwiftNIO SSH client", positive: true)]
        )
    }

    public static func buildOrchestration() -> CapabilityResult {
        CapabilityResult(
            kind: .buildOrchestration,
            availability: .limited("Runs on a connected remote host (for example a Mac). Requires an SSH host with the toolchain installed."),
            summary: "Remote Swift, Xcode and .NET builds and tests over SSH. Independent of the local mode.",
            evidence: [CapabilityEvidence(probe: "BuildOrchestrator module linked", observation: "remote execution only", positive: true)]
        )
    }
}

/// Used by the standard (Vanilla) app build, which does not link the Unleashed backend at all.
/// Reports Unleashed as unavailable without probing anything.
public struct UnleashedNotIncludedCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .unleashed

    public init() {}

    public func detectCapabilities() async -> CapabilityReport {
        let reason = "The Unleashed backend is not included in this build (standard distribution)."
        let local: [CapabilityResult] = [
            .localShell, .executableAccess, .filesystemPermissions, .packageManager,
            .processInspection, .privilegedOperations,
        ].map { CapabilityResult(kind: $0, availability: .unavailable(reason), summary: reason) }
        return CapabilityReport(
            mode: .unleashed,
            results: local + [SharedCapabilities.remoteSSH(), SharedCapabilities.buildOrchestration()],
            localFeaturesAvailable: false,
            headline: CapabilityReport.unleashedUnavailableMessage,
            buildNotes: ["Standard distribution build. Unleashed requires the separate Unleashed build on a supported device."]
        )
    }
}

/// Plain-text rendering of a capability report (for the `capabilities` built-in and exports).
public enum CapabilityReportFormatter {
    public static func text(_ report: CapabilityReport) -> String {
        var lines = ["\(report.mode.displayName) capabilities — \(report.headline)"]
        for result in report.results {
            lines.append("  \(result.kind.title.padding(toLength: 30, withPad: " ", startingAt: 0))\(result.availability.label)")
            if let detail = result.availability.detail { lines.append("      \(detail)") }
        }
        for note in report.buildNotes { lines.append("  Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}
