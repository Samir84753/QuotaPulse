# QuotaPulse – agent guide

QuotaPulse is a macOS 14+ menu bar app (SwiftUI `MenuBarExtra`, LSUIElement) that shows how much quota is left
for AI agent harnesses: **Claude Code, Codex, Antigravity**. It also has a desktop widget
(floating desktop-level panel) and an optional WidgetKit extension.

Lead/architect: Claude. You are a contributor executing ONE task brief. Stay inside its scope.

## Layout
- `Package.swift` – SwiftPM. Targets: `QuotaCore` (Foundation only, no UI), `QuotaPulse` (app), `QuotaCoreTests`.
- `Sources/QuotaCore/Models.swift` – `ProviderID`, `QuotaWindow` (usedPercent 0…100), `ProviderSnapshot`, `QuotaProvider`.
- `Sources/QuotaCore/Providers/*Provider.swift` – one file per harness. Pure `parse…` statics are unit-tested.
- `Sources/QuotaCore/Registry.swift` – concurrent fetch + `SnapshotStore` (JSON on disk, read by widgets).
- `Sources/QuotaPulse/` – app: `QuotaStore` (@Observable state, timer), menu views, settings, desktop widget.
- `scripts/build.sh [--test] [--install]` – builds `build/QuotaPulse.app` (ad-hoc signed).
- `QuotaPulse --json` (the built binary) prints live snapshots and exits – use it to verify providers.
- `docs/SPEC.md` – product spec & data-source contracts. `tasks/` – task briefs.

## Rules
1. Build with `swift build` and test with `swift test` before you finish. Zero errors. Fix warnings you introduce.
   If running in parallel with another agent, use `--build-path .build-$TASKID` to avoid lock contention.
2. Never print, log, commit or write tokens/secrets anywhere. Fixtures must be redacted (fake emails/tokens).
3. Never modify credential files (`~/.codex/auth.json`, Keychain). Read only.
   Never refresh the Claude OAuth token (it rotates and logs the user out of Claude Code).
4. Providers must never crash or hang: every network/subprocess call has a timeout; failures become a
   `ProviderSnapshot` with `.notConfigured` / `.needsLogin` / `.error` and a human message.
5. Keep `QuotaCore` UI-free. Keep public API stable unless the brief says otherwise.
6. Apple-platform skills are vendored in `.claude/skills/`:
   see `macos/macos-capabilities/menubar.md`, `macos/coding-best-practices`, `generators/widget-generator`,
   `swiftui/`, `testing/`. Follow them.
7. Do not `git commit` – the orchestrator commits after your task.
