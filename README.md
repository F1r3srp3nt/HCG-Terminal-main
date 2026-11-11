# HCG Terminal

Native SwiftUI terminal for iPhone and iPad by Hakmi Capital Group. Local commands, remote SSH development, remote Swift / Xcode / .NET builds and tests, logs and artifacts.

**Status: v0.1 development build.** The core modules are built and tested; the SwiftUI views and the iOS app targets have not yet been compiled with Xcode. See [`docs/STATUS.md`](docs/STATUS.md) for what is verified and what is not.

## Modes

| | Vanilla | Unleashed |
|---|---|---|
| For | Standard iPhone and iPad | Supported jailbroken devices (separate build) |
| Local terminal | Built-in commands on the app workspace | Real shell in a pseudo-terminal, or an existing local terminal service, **only where the device allows it** |
| Remote SSH, builds, Claude Code | Yes | Yes (same code, independent of mode) |
| Privileged actions | Never | Only after explicit approval of each action, with the permissions the device actually grants |
| Accent | HCG blue/green | Restrained violet |

The **Vanilla | Unleashed** selector sits in every session header and in Preferences. Switching never interrupts SSH sessions. Open local sessions keep running where they are unless you confirm restarting them in the other mode; nothing is ever transferred between environments.

If Unleashed is not available, the app says so:

> Unleashed features are not available in this environment. Vanilla terminal and remote development remain available.

## Layout

```
HCGTerminal.xcodeproj        two app targets sharing HCGTerminal/:
                               HCGTerminal           standard build (no Unleashed code linked)
                               HCGTerminalUnleashed  Unleashed build (adds UnleashedIntegration)
HCGTerminal/                 app entry point and composition root, assets
HCGTerminal-Support/         Info.plist additions, entitlements
HCGTerminalKit/              Swift package with all modules and tests
Scripts/                     test SSH server, Xcode project generator
docs/                        architecture, distribution, status
```

Modules (in `HCGTerminalKit/Sources`): TerminalCore, TerminalUI, LocalCommandEngine, VanillaExecutionProvider, UnleashedExecutionProvider, TerminalCapabilityProvider, RemoteSSH, FileWorkspace, DeveloperWorkspace, BuildOrchestrator, ArtifactManager, TerminalSecurity (the requested "Security" module; renamed so it does not shadow Apple's Security framework), Diagnostics, and UnleashedIntegration. Details in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Build

Requirements: Xcode 16 or later (Swift 6), iOS / iPadOS 17 or later.

```bash
open HCGTerminal.xcodeproj
# Scheme "HCGTerminal" for the standard build, "HCGTerminalUnleashed" for the Unleashed build.
```

Set your team under Signing & Capabilities. The app icon set is an empty placeholder.

### Package tests

```bash
cd HCGTerminalKit && swift test
```

The core modules use only Foundation and also build and test on Linux. Remote SSH integration tests need a disposable OpenSSH server:

```bash
sudo Scripts/start-test-sshd.sh          # Linux only; creates user hcgtest
HCG_SSH_TEST=1 swift test --package-path HCGTerminalKit
```

## Distribution

The standard build is meant for ordinary iOS / iPadOS distribution. The Unleashed build is separate and is **not** assumed to be eligible for the App Store. HCG Terminal never publishes or uploads anything — not to TestFlight, App Store Connect or any other channel. See [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md).
