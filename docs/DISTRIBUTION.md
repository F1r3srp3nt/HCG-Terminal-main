# Distribution

## Two targets

| | `HCGTerminal` (standard) | `HCGTerminalUnleashed` |
|---|---|---|
| Bundle ID | `com.hakmicapitalgroup.hcgterminal` | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Package products | TerminalUI, FileWorkspace | + UnleashedIntegration |
| Compilation condition | — | `HCG_UNLEASHED_BUILD` |
| Entitlements | `HCGTerminal-Support/HCGTerminal.entitlements` (empty) | `HCGTerminal-Support/HCGTerminalUnleashed.entitlements` (empty) |
| Intended channel | Ordinary iOS / iPadOS distribution | Separate; **not** assumed App Store eligible |

The standard target does not link `UnleashedExecutionProvider` or `UnleashedIntegration`, so it contains no `posix_spawn`, PTY or jailbreak-path code. Its Unleashed capability report comes from `UnleashedNotIncludedCapabilityProvider`, which probes nothing and reports the standard unavailable message. Selecting Unleashed in the standard build is safe: it changes a preference and shows that message.

Both targets share the sources in `HCGTerminal/`; the only difference in app code is the `#if HCG_UNLEASHED_BUILD` branch in `AppComposition`.

## Entitlements

Neither target requests special entitlements. On most jailbreaks a sandboxed app still cannot start processes, even with a shell installed; the Unleashed build then reports exactly that (the spawn error is shown, the capability becomes unavailable), and an existing local terminal service, if one is running, remains usable.

`HCGTerminal-Support/Unleashed-optional-entitlements.example.plist` documents the entitlement some installation methods use to run outside the sandbox. It is not referenced by any target. Using it is the device owner's decision; HCG Terminal never adds entitlements, bootstrap components or privileges by itself, and such a build cannot go through App Store or TestFlight.

## No automatic publishing

- No scheme has archive post-actions or upload scripts.
- The project contains no fastlane, altool, notarytool or App Store Connect configuration.
- Remote build plans and custom commands pass through `PublishingGuard`, which rejects upload and publish commands.

Archiving, signing for distribution and uploading are manual steps for the developer, outside HCG Terminal.
