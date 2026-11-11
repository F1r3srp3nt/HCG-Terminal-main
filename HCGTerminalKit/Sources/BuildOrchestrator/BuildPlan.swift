import DeveloperWorkspace
import Foundation
import TerminalCore

public enum BuildAction: String, Codable, CaseIterable, Sendable {
    case build, test, clean

    public var title: String { rawValue.capitalized }
}

public enum BuildConfiguration: String, Codable, CaseIterable, Sendable {
    case debug = "Debug"
    case release = "Release"
}

public enum XcodeDestination: Codable, Hashable, Sendable {
    case macOS
    case genericIOS
    case iOSSimulator(name: String)
    case custom(String)

    var argument: String {
        switch self {
        case .macOS: "platform=macOS"
        case .genericIOS: "generic/platform=iOS"
        case .iOSSimulator(let name): "platform=iOS Simulator,name=\(name)"
        case .custom(let value): value
        }
    }

    public var label: String {
        switch self {
        case .macOS: "My Mac"
        case .genericIOS: "Any iOS Device"
        case .iOSSimulator(let name): "\(name) (Simulator)"
        case .custom(let value): value
        }
    }
}

public enum BuildSystem: Codable, Hashable, Sendable {
    case swiftPackage
    case xcodeProject(name: String, scheme: String, destination: XcodeDestination)
    case xcodeWorkspace(name: String, scheme: String, destination: XcodeDestination)
    case dotnet(target: String?)

    public var label: String {
        switch self {
        case .swiftPackage: "Swift package"
        case .xcodeProject(let name, let scheme, _): "\(name) · \(scheme)"
        case .xcodeWorkspace(let name, let scheme, _): "\(name) · \(scheme)"
        case .dotnet(let target): ".NET" + (target.map { " · \($0)" } ?? "")
        }
    }
}

/// A fully specified remote build or test. The command line is generated, inspected by the
/// publishing guard, and shown to the user before it runs.
public struct BuildPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var hostName: String
    public var projectPath: String
    public var system: BuildSystem
    public var action: BuildAction
    public var configuration: BuildConfiguration
    /// The inner command (shown to the user).
    public var commandLine: String
    /// What is actually sent: login shell + `cd` + command.
    public var remoteCommand: String

    public var title: String { "\(action.title) \(system.label) (\(configuration.rawValue))" }
}

public enum BuildPlanError: Error, LocalizedError, Equatable {
    case publishingNotAllowed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .publishingNotAllowed(let what):
            "HCG Terminal never publishes or uploads automatically. Blocked: \(what). Run release steps yourself, outside HCG Terminal."
        case .unsupported(let what): what
        }
    }
}

/// Rejects commands that would publish or upload to TestFlight, App Store Connect, package
/// registries or other distribution channels. Applied to every planned and custom command.
public enum PublishingGuard {
    static let rules: [(pattern: String, description: String)] = [
        (#"\baltool\b"#, "xcrun altool (App Store Connect upload)"),
        (#"\bnotarytool\s+submit\b"#, "notarytool submit (uploads to Apple)"),
        (#"\biTMSTransporter\b"#, "iTMSTransporter (App Store upload)"),
        (#"-exportArchive\b"#, "xcodebuild -exportArchive (can upload with destination=upload)"),
        (#"\bfastlane\s+(\w+\s+)?(deliver|pilot|upload_to_testflight|upload_to_app_store|supply|appstore|beta|release)\b"#, "fastlane distribution lane"),
        (#"\b(deliver|pilot)\s+(upload|distribute)\b"#, "fastlane deliver/pilot upload"),
        (#"\bdotnet\s+nuget\s+push\b"#, "dotnet nuget push"),
        (#"\bnuget(\.exe)?\s+push\b"#, "nuget push"),
        (#"\bpod\s+trunk\s+push\b"#, "pod trunk push"),
        (#"\b(npm|yarn|pnpm)\s+publish\b"#, "npm publish"),
        (#"\bgh\s+release\s+(create|upload)\b"#, "GitHub release upload"),
        (#"\bfirebase\s+appdistribution\b"#, "Firebase App Distribution"),
        (#"\basc\s+(builds|apps|testflight)\b"#, "App Store Connect CLI"),
        (#"\btestflight\b"#, "TestFlight"),
    ]

    public static func check(_ command: String) throws {
        for rule in rules where command.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            throw BuildPlanError.publishingNotAllowed(rule.description)
        }
    }
}

public enum BuildPlanner {
    /// Build products for Xcode go to a project-local derived data folder so artifacts can be found.
    public static let derivedDataPath = ".hcg-build/DerivedData"

    public static func plan(
        host: HostProfile,
        projectPath: String,
        system: BuildSystem,
        action: BuildAction,
        configuration: BuildConfiguration = .debug
    ) throws -> BuildPlan {
        let command: String
        switch system {
        case .swiftPackage:
            switch action {
            case .build: command = "swift build -c \(configuration.rawValue.lowercased())"
            case .test: command = "swift test -c \(configuration.rawValue.lowercased())"
            case .clean: command = "swift package clean"
            }
        case .xcodeProject(let name, let scheme, let destination), .xcodeWorkspace(let name, let scheme, let destination):
            let containerFlag: String = if case .xcodeProject = system { "-project" } else { "-workspace" }
            var arguments = [
                "xcodebuild", containerFlag, name, "-scheme", scheme, "-configuration", configuration.rawValue,
                "-destination", destination.argument, "-derivedDataPath", derivedDataPath,
            ]
            if action == .build || action == .test, destination == .genericIOS {
                // Compile-check without signing; signing and distribution stay with the developer.
                arguments += ["CODE_SIGNING_ALLOWED=NO"]
            }
            arguments.append(action.rawValue)
            command = ShellQuote.join(arguments)
        case .dotnet(let target):
            let targetArgument = target.map { " " + ShellQuote.quote($0) } ?? ""
            switch action {
            case .build: command = "dotnet build\(targetArgument) -c \(configuration.rawValue)"
            case .test: command = "dotnet test\(targetArgument) -c \(configuration.rawValue)"
            case .clean: command = "dotnet clean\(targetArgument) -c \(configuration.rawValue)"
            }
        }
        try PublishingGuard.check(command)
        return BuildPlan(
            id: UUID(), hostID: host.id, hostName: host.name, projectPath: projectPath, system: system,
            action: action, configuration: configuration, commandLine: command,
            remoteCommand: RemoteShell.login(RemoteShell.inDirectory(projectPath, command + " 2>&1"))
        )
    }

    /// A user-written command (for example a test script). Still goes through the guard.
    public static func custom(host: HostProfile, projectPath: String, command: String) throws -> BuildPlan {
        try PublishingGuard.check(command)
        return BuildPlan(
            id: UUID(), hostID: host.id, hostName: host.name, projectPath: projectPath, system: .swiftPackage,
            action: .build, configuration: .debug, commandLine: command,
            remoteCommand: RemoteShell.login(RemoteShell.inDirectory(projectPath, command + " 2>&1"))
        )
    }
}
