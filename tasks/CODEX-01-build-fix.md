# CODEX-01 – Make it build and pass tests on macOS

The code was written on a machine without a macOS SDK, so it has never been compiled.

1. `swift build` – fix every compile error in `Sources/QuotaCore` and `Sources/QuotaPulse` with minimal,
   idiomatic changes (Swift 5.10 language mode, macOS 14 target). Typical suspects: `@Observable` + `didSet`
   in `QuotaStore`, `nonisolated(unsafe)` in `HeadlessMode`, `openSettings` availability (macOS 14 OK),
   `.background.secondary` shape style, `ContentUnavailableView`, Sendable warnings.
2. `swift test` – all `QuotaCoreTests` must pass. If a test is wrong about the fixture, fix the test; if the
   parser is wrong, fix the parser.
3. `./scripts/build.sh` must produce `build/QuotaPulse.app`. Then run
   `build/QuotaPulse.app/Contents/MacOS/QuotaPulse --json` and save the output to `.orchestration/smoke.json`
   **after replacing any email address with `<redacted>`**. (A Keychain prompt for "Claude Code-credentials" may
   appear; if the run blocks >60 s, kill it and note it in the report.)
4. Do not add features. Do not restructure.
Done when: build + tests green, app bundle exists, smoke.json written.
