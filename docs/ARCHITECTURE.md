# HCG Terminal architecture (v0.1)

## Modules

```
TerminalCore ─────────────────────────────────────────────────────────────┐
  ExecutionMode, ExecutionTarget, TerminalSession, LocalExecutionProvider,  │
  ModeSwitchPolicy, RemoteCommandExecuting, ShellQuote, EventChannel        │
                                                                            │
Diagnostics          DiagnosticLog, ProcessInspector, SystemSnapshot        │
TerminalSecurity     CredentialStore (Keychain), SSHKeyManager (Ed25519),   │ all depend
                     KnownHostsStore, PrivilegeClassifier, AuthorizationGate │ on Core
TerminalCapabilityProvider  protocol + CapabilityReport + SystemProbing     │
FileWorkspace        sandbox-confined filesystem (WorkspacePath)            │
LocalCommandEngine   parser, LineEditor, built-ins, BuiltinShellSession     │
                                                                            │
VanillaExecutionProvider    VanillaCapabilityProvider + built-in sessions   │
UnleashedExecutionProvider  scanner, UnleashedCapabilityProvider,           │
                            PTYProcess / ProcessRunner (posix_spawn),       │
                            LocalProcessSession, PackageManagerClient,      │
                            PermittedLocationBrowser                        │
RemoteSSH            SSHConnection (SwiftNIO SSH), SSHShellSession          │
DeveloperWorkspace   HostProfile, RemoteProjectBrowser, ToolchainProbe,     │
                     ProjectDetector, ClaudeCodeLauncher                    │
BuildOrchestrator    BuildPlanner, PublishingGuard, BuildOrchestrator,      │
                     BuildLogParser, ArtifactDiscovery                      │
ArtifactManager      ArtifactDownloader (SHA-256 verified), ArtifactIndex  ─┘

TerminalUI           TerminalAppModel, SessionModel, BuildCenter (Observation, testable on Linux)
                     SwiftUI views + SwiftTerm terminal view (Apple platforms only)
UnleashedIntegration wires UnleashedExecutionProvider into TerminalUI (Unleashed target only)
```

TerminalUI depends on the `LocalExecutionProvider` and `TerminalCapabilityProvider` protocols and on an `UnleashedTools` protocol it defines itself. It never imports `UnleashedExecutionProvider`; only `UnleashedIntegration` does, and only the Unleashed app target links that.

Third-party code: SwiftNIO, SwiftNIO SSH and swift-crypto (Apple), SwiftTerm 1.5.1 (terminal emulator, MIT). SwiftTerm is pinned to 1.5.1 because later 1.x releases depend on an unstable package version and use manifest syntax that needs Swift 6.1.

## Shared session abstraction

Every session — Vanilla built-ins, Unleashed PTY shell, local terminal service, remote SSH shell, Claude Code — implements `TerminalSession`:

- one immutable `target` (`.local(.vanilla)`, `.local(.unleashed)` or `.remote(endpoint)`), shown as **Local Vanilla**, **Local Unleashed** or **Remote Host**;
- a `backend` describing what actually executes input;
- raw-byte input, an ordered `AsyncStream<TerminalEvent>` of output and state, resize, interrupt, close.

Execution providers stay isolated: each creates its own session type, and a session only ever executes on its own target. The built-in session hands unknown commands to an `ExternalCommandHandler`; the Vanilla handler refuses them (exit 127). Nothing forwards a local command to a remote host.

## Mode switching and session safety

`ModeSwitchPolicy` (pure, unit-tested) decides what a mode change means:

| Session | Effect of switching the preferred mode |
|---|---|
| Remote | None. Never closed, interrupted or re-targeted. |
| Local, already in the new mode | None. |
| Local, idle, other mode | Stays where it is. The user is offered to restart it in the new mode; only explicitly selected sessions restart, as fresh sessions. |
| Local, running a command | Must stay. Running commands are never transferred. |
| Any local, new mode unavailable | Must stay. |

The preferred mode is saved in `UserDefaults` (`hcg.terminal.preferredLocalMode`) and only decides where *new* local sessions open. `TerminalAppModel.openLocalSession` never falls back to another mode or to a remote host.

## Capability detection

`TerminalCapabilityProvider.detectCapabilities()` returns a `CapabilityReport` with one `CapabilityResult` per kind — local shell, executable access, filesystem permissions, package manager, process inspection, privileged operations, remote SSH, build/test orchestration — each with an availability (`available`, `limited`, `unverified`, `requiresAuthorization`, `unavailable`) and the evidence used.

Detection is read-only: `lstat`, `access(2)`, directory listing, a `sysctl` read of the process table, `geteuid()`, and TCP connects to 127.0.0.1:22/2222 without sending data. It never writes, spawns, loads code or asks for privileges.

Unleashed is capability-based, not "is jailbroken?"-based. `/var/jb` existing proves nothing on its own (tested). A shell that is present and executable is reported as **detected, not yet verified**; it becomes **available** only after a Local Unleashed session actually started it, or **unavailable** with the real `errno` if starting failed (`RuntimeObservations`).

## Unleashed execution

- **Direct shell**: `PTYProcess` opens a pseudo-terminal and `posix_spawn`s the detected shell in a new session with default signals and an explicit, minimal environment. No `fork`, no `system`, no private APIs.
- **Existing local terminal service**: if a service accepts connections on 127.0.0.1, the user can sign in with that service's own account; the session uses RemoteSSH but its target is Local Unleashed because commands run on the device.
- **Privileged commands**: `CommandGuard` keeps a shadow copy of the typed line. When Return ends a line that `PrivilegeClassifier` flags (sudo/su, package changes, launchctl, killall, writes to system paths, …), Return is held and `AuthorizationGate` asks the user. Declined lines are erased without running (Ctrl-E, Ctrl-U). The guard is suspended in full-screen programs and at password prompts, and it is best-effort: commands recalled with shell history are not visible to it. The actual guarantee is structural — HCG Terminal never adds `sudo`, never supplies passwords and never changes security settings; elevation happens only through tools the user runs.
- **Packages**: listing (`dpkg-query`) is read-only. Install/remove/refresh produce the exact `apt` command line only after explicit approval and run visibly in a new Local Unleashed session.
- **Files and logs**: read-only browsing of locations the scan found readable.

Known limitation on Darwin: the spawned shell gets the PTY as stdio but not as its controlling terminal (posix_spawn cannot issue `TIOCSCTTY`), so job control is limited; Ctrl-C is also sent as SIGINT to the shell's process group.

## Remote development

`SSHConnection` (SwiftNIO SSH) authenticates with a password or an Ed25519 key from the Keychain. Host keys are checked against a known-hosts store: unknown keys need explicit approval with the OpenSSH-format fingerprint; changed keys are refused without a prompt. Sessions are channels on one connection, so closing one leaves the others running.

Developer tools depend only on `RemoteCommandExecuting`, so they work identically in both modes:

- `RemoteProjectBrowser` lists directories with portable POSIX shell; `ProjectDetector` recognises SwiftPM, Xcode projects/workspaces and .NET solutions/projects.
- `BuildPlanner` produces `swift`, `xcodebuild` (with a project-local derived-data path and, for device builds, `CODE_SIGNING_ALLOWED=NO`) or `dotnet` commands, run in the remote login shell. `PublishingGuard` rejects altool, notarytool submit, iTMSTransporter, `-exportArchive`, fastlane distribution lanes, nuget/npm/pod publishing, GitHub releases, Firebase App Distribution and TestFlight in planned and custom commands.
- `BuildOrchestrator` streams output to a log file in the workspace, extracts diagnostics (swiftc/clang and MSBuild formats) and test summaries (XCTest, Swift Testing, dotnet test).
- `ArtifactDiscovery` finds products; `ArtifactDownloader` streams them over the exec channel and checks SHA-256 against `shasum -a 256`/`sha256sum` on the host (directories are sent as tar).
- Claude Code runs on the remote host in its own PTY session (`$SHELL -lc 'cd <project> && exec claude'`).

## Interface

- `ModeSelector` follows HCG ONE's `ExperienceSwitcher` (Website | App) in `ios-hcg/HCGONE/Views/Website/WebsiteExperienceView.swift`: capsule track on `surface2` with a 1-pt `line` stroke and 2-pt inset, icon + label segments, `.snappy` animation, `.isSelected` accessibility trait, compact variant. HCG Terminal adds a sliding thumb (`matchedGeometryEffect`) filled with the mode gradient, selection haptics, Reduce Motion support and an availability dot. It is not a pixel-identical copy, and it has not yet been compared side by side on a device.
- Colors: surfaces, lines and text come from HCG ONE's `Palette`. HCG ONE's accent is silver; there is no blue/green accent there, so the Vanilla blue/green pair uses HCG ONE's `info` (#5C8CC4) and `gain` (#5E9C76) tokens. Unleashed uses a desaturated violet (#8A7FC4 → #5E5596).
- Session header: title, target badge, target detail, mode selector, interrupt, details, close, and a one-line capability status.
- Session details: target, location, backend, the session's own mode, the active local mode, state and an explanation of what a mode switch does to this session.
- Preferences: mode selector, both capability reports with evidence, build information, SSH keys and known hosts.
