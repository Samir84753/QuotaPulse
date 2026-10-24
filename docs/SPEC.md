# QuotaPulse – Product & Technical Spec (v1)

**Goal:** one glance at the menu bar tells you how much of each AI coding harness's quota is left.

## Users & surfaces
- **Menu bar item** (always): gauge icon reflecting the tightest window + text, e.g. `C 63% · X 78% · A 95%`
  (remaining by default; style configurable: every provider / most constrained / icon only).
- **Popover** (click): one card per provider – plan badge, every window with a bar, % left, "resets in …", account, status/error.
- **Desktop widget**: floating desktop-level panel (no signing needed), draggable, all Spaces. Toggle in popover/settings.
- **WidgetKit widget** (optional Xcode build, needs signing + App Group): small & medium families, reads `SnapshotStore`.
- **Settings**: providers on/off, menu bar style, remaining vs used, refresh interval (1–60 min, default 5), launch at login.
- **CLI**: `QuotaPulse --json` prints snapshots.

## Data sources (read-only; reuse logins the CLIs already have)
| Provider | Credentials | Endpoint | Windows |
|---|---|---|---|
| Claude Code | Keychain `Claude Code-credentials` → `~/.claude/.credentials.json` | `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | `five_hour`, `seven_day`, `seven_day_opus/sonnet` (`utilization` %) |
| Codex | `~/.codex/auth.json` (`tokens.access_token`, `account_id`) | `GET chatgpt.com/backend-api/wham/usage` (+`ChatGPT-Account-Id`) ; fallback newest `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits` | primary (5h), secondary (weekly), additional |
| Antigravity | running `language_server` (`--csrf_token`) via `ps` + `lsof` | `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus` (RetrieveUserQuotaSummary preferred) | per-model `quotaInfo.remainingFraction` |

## Non-negotiables
- Never write/refresh-and-persist credentials; never refresh Claude token (rotation logs user out).
- Every call has a timeout; a provider failure never blocks others (TaskGroup) or the UI.
- Transient errors keep the last good snapshot marked "Stale".
- No telemetry. Only the providers' own endpoints are contacted.

## Architecture
`QuotaCore` (Foundation; models, providers, registry, snapshot store) ← `QuotaPulse` (SwiftUI MenuBarExtra app,
@Observable `QuotaStore`, timer loop) ; optional `QuotaPulseWidget` (WidgetKit, XcodeGen project).

## Team / orchestration
| Task | Owner | Phase |
|---|---|---|
| Architecture, core, providers v0, UI, tests, briefs | Claude (lead) | 0 ✅ |
| CODEX-01 build & fix on macOS | codex | 1 |
| CODEX-02 Claude/Codex live verification | codex | 2 ∥ |
| AGY-01 Gemini/Antigravity live verification + QuotaSummary + agy CLI | agy | 2 ∥ |
| AGY-02 WidgetKit extension (XcodeGen) | agy | 2b |
| CODEX-03 review, icon, README, install | codex | 3 |
| Acceptance review of reports + smoke output | Claude | 4 |
