# CODEX-02 – Verify Claude Code + Codex providers against this Mac's real logins

Files you own: `Sources/QuotaCore/Providers/ClaudeProvider.swift`, `CodexProvider.swift`, their tests/fixtures.
Use `--build-path .build-codex02` (agy is building in parallel).

1. Run the built binary with `--json` (or a small `swift run` harness) and check the `claude` and `codex` snapshots.
2. Claude: confirm the Keychain read (`security find-generic-password -s "Claude Code-credentials" -w`) parses,
   and `GET https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`) returns
   `five_hour` / `seven_day` / model windows. Adapt parsing to the real response shape (e.g. new keys like
   `seven_day_opus`, `limits[]`). Do NOT refresh tokens.
3. Codex: confirm `~/.codex/auth.json` parsing and `GET https://chatgpt.com/backend-api/wham/usage`
   (`ChatGPT-Account-Id` header). Confirm the session-log fallback against a real `~/.codex/sessions/**/rollout-*.jsonl`
   and that it only scans the newest few files (performance: must finish < 1 s).
4. Add redacted fixtures from the real responses (replace emails/ids/tokens) and tests for any new shape.
5. Report the real window labels/percentages you saw (no identifiers) in the report.
