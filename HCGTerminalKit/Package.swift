// swift-tools-version: 6.0
import PackageDescription

// HCGTerminalKit — the modules behind HCG Terminal for iPhone and iPad.
//
// Layering (lower layers never import higher ones):
//
//   TerminalCore                 shared session abstraction, execution targets, mode-switch policy. Foundation only.
//   Diagnostics                  structured log, process inspection, system snapshot.
//   TerminalSecurity             credentials (Keychain), SSH keys, known hosts, privilege classifier, authorization gate.
//   TerminalCapabilityProvider   the TerminalCapabilityProvider interface and its structured results.
//   FileWorkspace                sandbox-confined local filesystem.
//   LocalCommandEngine           command parser, line discipline and the built-in commands.
//   VanillaExecutionProvider     standard iOS/iPadOS local execution (built-ins on the sandbox only).
//   UnleashedExecutionProvider   optional jailbreak backend. Linked ONLY by the Unleashed app target.
//   RemoteSSH                    SSH transport (SwiftNIO SSH), PTY shells, exec channels.
//   DeveloperWorkspace           host profiles, remote project browsing, project detection.
//   BuildOrchestrator            remote Swift / Xcode / .NET build and test runs, log parsing.
//   ArtifactManager              artifact index and verified downloads.
//   TerminalUI                   SwiftUI interface. Views compile on Apple platforms only.
//   UnleashedIntegration         wires the Unleashed backend into TerminalUI (Unleashed app target only).
//
// The module the request calls "Security" is named `TerminalSecurity` so it does not shadow
// Apple's Security framework (which it imports for Keychain access).
let package = Package(
    name: "HCGTerminalKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "TerminalSecurity", targets: ["TerminalSecurity"]),
        .library(name: "TerminalCapabilityProvider", targets: ["TerminalCapabilityProvider"]),
        .library(name: "FileWorkspace", targets: ["FileWorkspace"]),
        .library(name: "LocalCommandEngine", targets: ["LocalCommandEngine"]),
        .library(name: "VanillaExecutionProvider", targets: ["VanillaExecutionProvider"]),
        .library(name: "UnleashedExecutionProvider", targets: ["UnleashedExecutionProvider"]),
        .library(name: "RemoteSSH", targets: ["RemoteSSH"]),
        .library(name: "DeveloperWorkspace", targets: ["DeveloperWorkspace"]),
        .library(name: "BuildOrchestrator", targets: ["BuildOrchestrator"]),
        .library(name: "ArtifactManager", targets: ["ArtifactManager"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        // Linked only by the Unleashed app target.
        .library(name: "UnleashedIntegration", targets: ["UnleashedIntegration"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.1"),
    ],
    targets: [
        .target(name: "TerminalCore"),
        .target(name: "Diagnostics", dependencies: ["TerminalCore"]),
        .target(
            name: "TerminalSecurity",
            dependencies: ["TerminalCore", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(name: "TerminalCapabilityProvider", dependencies: ["TerminalCore"]),
        .target(name: "FileWorkspace", dependencies: ["TerminalCore"]),
        .target(name: "LocalCommandEngine", dependencies: ["TerminalCore", "FileWorkspace"]),
        .target(
            name: "VanillaExecutionProvider",
            dependencies: ["TerminalCore", "TerminalCapabilityProvider", "LocalCommandEngine", "FileWorkspace", "Diagnostics"]
        ),
        .target(
            name: "UnleashedExecutionProvider",
            dependencies: [
                "TerminalCore", "TerminalCapabilityProvider", "LocalCommandEngine", "FileWorkspace",
                "TerminalSecurity", "Diagnostics",
            ]
        ),
        .target(
            name: "RemoteSSH",
            dependencies: [
                "TerminalCore", "TerminalSecurity", "Diagnostics",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(name: "DeveloperWorkspace", dependencies: ["TerminalCore"]),
        .target(name: "BuildOrchestrator", dependencies: ["TerminalCore", "DeveloperWorkspace", "Diagnostics"]),
        .target(
            name: "ArtifactManager",
            dependencies: ["TerminalCore", "FileWorkspace", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "TerminalUI",
            dependencies: [
                "TerminalCore", "TerminalCapabilityProvider", "TerminalSecurity", "Diagnostics", "FileWorkspace",
                "LocalCommandEngine", "VanillaExecutionProvider", "RemoteSSH", "DeveloperWorkspace",
                "BuildOrchestrator", "ArtifactManager",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .target(
            name: "UnleashedIntegration",
            dependencies: [
                "TerminalUI", "UnleashedExecutionProvider", "TerminalCapabilityProvider", "TerminalCore",
                "TerminalSecurity", "FileWorkspace",
            ]
        ),

        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        .testTarget(name: "TerminalSecurityTests", dependencies: ["TerminalSecurity", "TerminalCore"]),
        .testTarget(name: "FileWorkspaceTests", dependencies: ["FileWorkspace", "TerminalCore"]),
        .testTarget(name: "LocalCommandEngineTests", dependencies: ["LocalCommandEngine", "FileWorkspace", "TerminalCore"]),
        .testTarget(
            name: "ExecutionProviderTests",
            dependencies: [
                "VanillaExecutionProvider", "UnleashedExecutionProvider", "TerminalCapabilityProvider",
                "TerminalSecurity", "LocalCommandEngine", "FileWorkspace", "TerminalCore", "Diagnostics",
            ]
        ),
        .testTarget(name: "RemoteSSHTests", dependencies: ["RemoteSSH", "TerminalSecurity", "TerminalCore"]),
        .testTarget(
            name: "DeveloperToolsTests",
            dependencies: ["DeveloperWorkspace", "BuildOrchestrator", "ArtifactManager", "FileWorkspace", "TerminalCore"]
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI", "TerminalCore", "TerminalCapabilityProvider", "TerminalSecurity", "FileWorkspace", "LocalCommandEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
