import Foundation
import TerminalCore

/// Why a command needs explicit authorization.
public struct PrivilegeAssessment: Hashable, Sendable {
    public var requiresAuthorization: Bool
    public var reasons: [String]

    public static let unprivileged = PrivilegeAssessment(requiresAuthorization: false, reasons: [])
}

/// Classifies local Unleashed command lines that could change privileges, packages, system
/// locations or device state. Deliberately conservative: when in doubt it asks.
///
/// The classifier never rewrites a command and never adds `sudo`; authorization only lets the
/// command run exactly as typed, with whatever permissions the device actually grants.
public enum PrivilegeClassifier {
    static let elevationTools: Set<String> = ["sudo", "su", "doas", "pkexec"]
    static let packageTools: Set<String> = ["apt", "apt-get", "dpkg", "aptitude", "brew", "port", "pip", "pip3", "npm", "gem"]
    static let packageMutatingVerbs: Set<String> = [
        "install", "reinstall", "remove", "purge", "upgrade", "dist-upgrade", "full-upgrade", "autoremove",
        "update", "uninstall", "-i", "--install", "-r", "--remove", "-P", "--purge", "--configure", "--unpack",
    ]
    /// Tools that change device or system state whatever their arguments.
    static let deviceStateTools: Set<String> = [
        "launchctl", "reboot", "shutdown", "halt", "ldrestart", "sbreload", "killall", "userspace_reboot",
        "uicache", "mount", "umount", "nvram", "csrutil", "spctl", "ldid", "codesign", "jbctl", "mkfs",
        "diskutil", "dd", "kill", "pkill",
    ]
    /// Tools that are only privileged when they touch a protected location.
    static let pathSensitiveTools: Set<String> = [
        "rm", "rmdir", "mv", "cp", "ln", "chmod", "chown", "chgrp", "chflags", "touch", "mkdir", "tee", "install", "rsync",
    ]
    /// Wrappers whose first non-option argument is the real command.
    static let wrappers: Set<String> = ["env", "nohup", "time", "exec", "command", "nice", "xargs"]
    /// Path prefixes that belong to the system or the jailbreak environment.
    static let protectedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/Library", "/Applications",
        "/var/jb", "/private/preboot", "/private/var/containers", "/var/containers", "/dev",
        "/private/var/db", "/var/db", "/cores", "/boot", "/lib", "/opt",
    ]

    static func isProtected(_ argument: String) -> Bool {
        protectedPrefixes.contains { argument == $0 || argument.hasPrefix($0 + "/") }
    }

    public static func assess(_ commandLine: String) -> PrivilegeAssessment {
        var reasons: [String] = []
        func add(_ reason: String) { if !reasons.contains(reason) { reasons.append(reason) } }

        for segment in commandLine.split(whereSeparator: { ";|&\n()`".contains($0) }) {
            var words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            // Skip leading VAR=value assignments and transparent wrappers.
            while let first = words.first {
                let tool = (first as NSString).lastPathComponent
                if first.contains("=") && !first.hasPrefix("-") { words.removeFirst(); continue }
                if wrappers.contains(tool) {
                    words.removeFirst()
                    while let next = words.first, next.hasPrefix("-") || (next.contains("=") && tool == "env") { words.removeFirst() }
                    continue
                }
                break
            }
            guard let first = words.first else { continue }
            let tool = (first as NSString).lastPathComponent
            let arguments = Array(words.dropFirst())

            if elevationTools.contains(tool) { add("`\(tool)` requests elevated privileges.") }
            if packageTools.contains(tool), arguments.contains(where: packageMutatingVerbs.contains) {
                add("`\(tool)` would change installed packages.")
            }
            if deviceStateTools.contains(tool) { add("`\(tool)` can change device or system state.") }
            if tool == "sysctl", arguments.contains(where: { $0 == "-w" || $0.contains("=") }) {
                add("`sysctl` would change a kernel setting.")
            }
            if pathSensitiveTools.contains(tool), arguments.contains(where: isProtected) {
                add("`\(tool)` targets a protected system location.")
            }
        }
        // Redirections into protected locations, e.g. `echo x > /etc/hosts`.
        let redirectTargets = commandLine.components(separatedBy: ">").dropFirst().compactMap {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "> \t")).split(separator: " ").first.map(String.init)
        }
        if redirectTargets.contains(where: isProtected) { add("Output is redirected into a protected system location.") }
        return PrivilegeAssessment(requiresAuthorization: !reasons.isEmpty, reasons: reasons)
    }
}

/// A request shown to the user. Every privileged action creates exactly one request.
public struct AuthorizationRequest: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var commandLine: String
    public var target: ExecutionTarget
    public var reasons: [String]

    public init(id: UUID = UUID(), title: String, commandLine: String, target: ExecutionTarget, reasons: [String]) {
        self.id = id
        self.title = title
        self.commandLine = commandLine
        self.target = target
        self.reasons = reasons
    }
}

public struct AuthorizationRecord: Hashable, Sendable {
    public var request: AuthorizationRequest
    public var granted: Bool
    public var decidedAt: Date
}

/// Routes privileged actions through an explicit user decision. There is no "always allow":
/// each request is decided individually, and a missing presenter means denial.
public actor AuthorizationGate {
    public typealias Presenter = @Sendable (AuthorizationRequest) async -> Bool

    private var presenter: Presenter?
    private var history: [AuthorizationRecord] = []

    public init(presenter: Presenter? = nil) {
        self.presenter = presenter
    }

    public func setPresenter(_ presenter: Presenter?) {
        self.presenter = presenter
    }

    /// Returns true only if the user explicitly approved this specific request.
    public func requestAuthorization(_ request: AuthorizationRequest) async -> Bool {
        guard let presenter else {
            history.append(AuthorizationRecord(request: request, granted: false, decidedAt: Date()))
            return false
        }
        let granted = await presenter(request)
        history.append(AuthorizationRecord(request: request, granted: granted, decidedAt: Date()))
        return granted
    }

    public func auditTrail() -> [AuthorizationRecord] { history }
}
