# CODEX-03 – Integration review, polish, install

1. Review every change since the baseline commit (`git log -p`) for: secrets in fixtures/logs, crashes,
   main-thread blocking, missing timeouts, credential-file writes. Fix what you find.
2. `swift test` green; `./scripts/build.sh --install` (installs to ~/Applications and launches).
3. Generate a simple app icon (`Resources/AppIcon.icns`, e.g. via a small Swift/AppKit script + `iconutil`)
   and add `CFBundleIconFile` to Info.plist.
4. Update `README.md` with: install, permissions (one-time Keychain prompt), how each provider is read,
   desktop widget, WidgetKit build, troubleshooting.
5. Write `.orchestration/FINAL.md`: what works per provider (from a final `--json` run, redacted), known gaps.

## Lead notes from AGY-01 review (Claude)
- `testGeminiOAuthClientDiscovery` depends on this Mac's gemini-cli install: make it `XCTSkip` when no client is found so CI/other machines pass.
- Gemini currently returns `needsLogin` (Google `invalid_grant` on refresh). That is the user's expired Gemini login, not a bug — keep the message actionable ("run `gemini` and sign in again").
- Check the Antigravity 5.5 s task-group timeout cancels child processes/requests cleanly and that the menu shows the 4 Antigravity windows with readable labels.
- In the popover, cap each provider card to its 4 most-used windows with a "show all" disclosure so Gemini's many model buckets don't overflow.
