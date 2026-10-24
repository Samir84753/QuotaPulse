# AGY-01 – Gemini CLI + Antigravity providers, verified live

Files you own: `Sources/QuotaCore/Providers/GeminiProvider.swift`, `AntigravityProvider.swift`, their tests/fixtures.
Use `swift build --build-path .build-agy01` and `swift test --build-path .build-agy01` (codex builds in parallel).

Gemini CLI:
1. Verify `~/.gemini/oauth_creds.json` parsing, in-memory token refresh using the OAuth client id/secret found in the
   installed gemini-cli JS (`GeminiProvider.oauthClient()` – check it actually finds them for this install layout,
   including bundled builds), `loadCodeAssist` and `retrieveUserQuota`. Never write the creds file.
2. Make labels friendly (e.g. "Gemini 2.5 Pro") and drop `_vertex` duplicates.

Antigravity:
3. With the Antigravity app/IDE (or a running `agy`) open, verify process detection (`ps`), port discovery (`lsof`),
   and `GetUserStatus`. Also implement `RetrieveUserQuotaSummary` as the PREFERRED call
   (`response.groups[].buckets[]` with `displayName`, `remaining.remainingFraction`, reset prose in `description`)
   falling back to `GetUserStatus` → `cascadeModelConfigData.clientModelConfigs[].quotaInfo`.
4. Add support for the `agy` CLI's embedded server (no CSRF token needed) when only `agy` is running.
5. Total Antigravity fetch must complete < 6 s even when nothing answers.
6. Redacted fixtures + tests for each real response shape you observe.
