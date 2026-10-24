# QuotaPulse

A macOS 14+ menu bar app showing remaining quota for **Claude Code, Codex, and Antigravity**. Includes a floating desktop panel and an optional native WidgetKit extension.

## Install and run

Requires the Swift/Xcode command line tools. From this repository:

```bash
swift build
swift test
./scripts/build.sh --install
```

The script creates an ad-hoc signed `build/QuotaPulse.app`, installs it in `~/Applications`, and launches it. Look for the gauge in the menu bar; there is no Dock icon. Re-run the script to update. `./scripts/build.sh --test --install` also runs tests before installation.

Open the menu for quota cards and Refresh, Settings, desktop widget, and Quit controls. Cards show the four most-used windows first; **Show all** expands additional buckets. Settings controls providers, refresh interval (default five minutes), remaining/used display, menu bar style, and launch at login. A transient error retains the last good quota with a **Stale** message.

## Permissions and credentials

First use may show a one-time Keychain prompt for **Claude Code-credentials**. Choose **Always Allow** if you want unattended Claude refreshes. Rebuilding or changing signing identity can cause macOS to ask again. If the prompt times out, approve access and refresh again.

QuotaPulse reads existing CLI credentials; sign in through the corresponding CLI first. It never writes credential files or Keychain items and never refreshes Claude's OAuth token. Requests go to the providers' own endpoints, or the Antigravity server on loopback. No separate QuotaPulse account is needed.

## Provider data sources

| Provider | Read method | Recovery |
| --- | --- | --- |
| Claude Code | Read `Claude Code-credentials` through `/usr/bin/security`, with `~/.claude/.credentials.json` as fallback. Query `https://api.anthropic.com/api/oauth/usage` for session and weekly windows, including model windows when present. | Run `claude` and sign in/refresh there if login expires. |
| Codex | Read `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) and query `https://chatgpt.com/backend-api/wham/usage`. If the request fails, inspect the final 2 MiB of each of the five newest `sessions/**/rollout-*.jsonl` files for recorded rate limits. | Run `codex login` for a ChatGPT subscription login. API-key-only usage has no subscription quota. Session fallback reflects the last recorded turn. |
| Antigravity | Discover the running language server with `ps`/`lsof`. Query loopback `RetrieveUserQuotaSummary`, falling back to `GetUserStatus`. Supports Gemini and Claude/GPT weekly and five-hour buckets. Self-signed TLS is accepted only on loopback. | Open Antigravity or run `agy`. Refresh after its language server starts. Fetch has a 5.5-second deadline. |

All HTTP requests and subprocesses have timeouts. Credentials stay in memory during fetches. Cached snapshots contain quota, optional account/plan details, and status messages, with no tokens. They live in the App Group container when available, otherwise `~/Library/Application Support/QuotaPulse/snapshots.json`.

## Desktop widget

Use the rectangle button in the menu or **Settings → Display → Show desktop widget**. This draggable desktop-level panel works with the standard installation, needs no WidgetKit provisioning, and shows the tightest window per enabled provider. Right-click it to refresh or hide it. Its position is saved.

## Native WidgetKit build

The SwiftPM installation includes the floating panel. To build the optional small/medium widgets for the macOS widget gallery, install full Xcode and XcodeGen, configure signing and the shared App Group, then build:

```bash
brew install xcodegen
QUOTAPULSE_TEAM_ID=XXXXXXXXXX ./scripts/build-xcode.sh -derivedDataPath build/DerivedData
```

Use your actual Apple Developer Team ID. Both targets must support `group.com.quotapulse.shared`. Install the resulting `build/DerivedData/Build/Products/Release/QuotaPulse.app` in `~/Applications`, launch it, then use **Edit Widgets → QuotaPulse**. See [WidgetKit setup](docs/WIDGET.md) for provisioning details. Widget timelines read cached app snapshots; keep the menu bar app running for fresh quota. WidgetKit controls the refresh schedule.

To verify compilation without provisioning:

```bash
./scripts/build-xcode.sh CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData
```

An unsigned extension build does not establish widget gallery availability.

## Troubleshooting

- **No Dock icon:** expected for a menu bar app. Open `~/Applications/QuotaPulse.app` and find its gauge in the menu bar.
- **Login needed:** use the provider CLI to sign in, then refresh. QuotaPulse cannot rotate Claude credentials.
- **Claude unavailable after denying Keychain access:** allow the credential read when prompted on a subsequent refresh. Check that Claude Code itself is signed in.
- **Antigravity missing/timed out:** open the IDE and wait for its local language server; a remote-only CLI session may expose no local quota server.
- **Stale data or a network error:** check connectivity and refresh. Provider APIs are internal and may change. Codex session-log fallback can be older than live usage.
- **Widget missing/empty:** the normal install has only the floating panel. Native widgets need the Xcode build, signing/App Group setup, and at least one app refresh. WidgetKit refreshes can lag.
- **Diagnostic output:** `~/Applications/QuotaPulse.app/Contents/MacOS/QuotaPulse --json` fetches live snapshots and exits. Output can include account email and plan details; redact these before sharing it.

## Development

`QuotaCore` contains Foundation-only providers and parsers; SwiftUI/AppKit code lives in `Sources/QuotaPulse`. Fixtures use fake/redacted credentials. See [the product spec](docs/SPEC.md) and `tasks/` for contracts and task briefs.

The bundled icon is reproducible with:

```bash
swift scripts/generate-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Optional project orchestration scripts are `scripts/install-skills.sh` and `scripts/orchestrate.sh`; their progress and reports live in `.orchestration/`.
