import Foundation
import XCTest
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testClaudeUsage() throws {
        let w = try ClaudeProvider.parseUsage(fixture("claude_usage.json"))
        XCTAssertEqual(w.map(\.label), ["Session (5h)", "Weekly", "Weekly · Sonnet"])
        XCTAssertEqual(w[0].usedPercent, 37, accuracy: 0.01)
        XCTAssertNotNil(w[0].resetsAt, "microsecond ISO timestamps must parse")
    }

    func testClaudeCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1893456000000,"subscriptionType":"max"}}"#
        let c = try ClaudeProvider.parseCredentials(Data(json.utf8))
        XCTAssertEqual(c.accessToken, "tok")
        XCTAssertEqual(c.subscriptionType, "max")
        XCTAssertEqual(c.expiresAt?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
    }

    func testCodexUsage() throws {
        let r = try CodexProvider.parseUsage(fixture("codex_usage.json"))
        XCTAssertEqual(r.plan, "Plus")
        XCTAssertEqual(r.windows.map(\.label), ["Session (5h)", "Weekly"])
        XCTAssertEqual(r.windows[1].usedPercent, 61)
    }

    func testCodexSessionLog() throws {
        let text = String(decoding: try fixture("codex_rollout.jsonl"), as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").last)
        let w = try XCTUnwrap(CodexProvider.parseRateLimitsLine(line, fileDate: Date()))
        XCTAssertEqual(w.map(\.label), ["Session (5h)", "Weekly"])
        XCTAssertEqual(w[1].usedPercent, 48)
    }

    func testAntigravityUserQuotaSummary() throws {
        let windows = try AntigravityProvider.parseUserQuotaSummary(fixture("antigravity_quota_summary.json"))
        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(windows.map(\.label), [
            "Gemini · Weekly",
            "Gemini · 5-Hour",
            "Claude and GPT · Weekly",
            "Claude and GPT · 5-Hour"
        ])
        XCTAssertEqual(windows[0].id, "agy-gemini-weekly")
        XCTAssertEqual(windows[0].windowSeconds, 604_800)
        XCTAssertEqual(windows[0].usedPercent, 21.6, accuracy: 0.01)
        XCTAssertNotNil(windows[0].resetsAt)

        XCTAssertEqual(windows[1].id, "agy-gemini-5h")
        XCTAssertEqual(windows[1].windowSeconds, 18_000)
        XCTAssertEqual(windows[1].usedPercent, 2.0, accuracy: 0.01)

        XCTAssertEqual(windows[2].id, "agy-3p-weekly")
        XCTAssertEqual(windows[2].usedPercent, 100, accuracy: 0.01)

        XCTAssertEqual(windows[3].id, "agy-3p-5h")
        XCTAssertEqual(windows[3].usedPercent, 0, accuracy: 0.01)
    }

    func testAntigravity() throws {
        let r = try AntigravityProvider.parseUserStatus(fixture("antigravity_status.json"))
        XCTAssertEqual(r.email, "me@example.com")
        XCTAssertEqual(r.plan, "Pro")
        XCTAssertEqual(r.windows.count, 2)
        XCTAssertEqual(r.windows[0].usedPercent, 40, accuracy: 0.01)

        let ps = """
          123 /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --app_data_dir antigravity --csrf_token abc --extension_server_port 5555
          456 /usr/bin/other --csrf_token zzz
          789 /Users/test/.local/bin/agy -p "some task"
          790 agy
        """
        let procs = AntigravityProvider.parseProcessList(ps)
        XCTAssertEqual(procs.count, 3)
        XCTAssertEqual(procs[0], .init(pid: 123, csrfToken: "abc", extensionPort: 5555, extensionCsrfToken: nil))
        XCTAssertEqual(procs[1].pid, 789)
        XCTAssertEqual(procs[2].pid, 790)

        let lsof = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_ 123 me   12u  IPv4 0xabc      0t0  TCP 127.0.0.1:53412 (LISTEN)
        language_ 123 me   13u  IPv4 0xabd      0t0  TCP 127.0.0.1:53413 (LISTEN)
        """
        XCTAssertEqual(AntigravityProvider.parseListeningPorts(lsof), [53412, 53413])
    }

    func testHeadlineIsMostConstrained() {
        let s = ProviderSnapshot(provider: .claude, state: .ok, windows: [
            QuotaWindow(id: "a", label: "a", usedPercent: 10),
            QuotaWindow(id: "b", label: "b", usedPercent: 80),
        ])
        XCTAssertEqual(s.headline?.id, "b")
    }

    // MARK: - ClaudeCostEstimator

    func testCostEstimatorParsesUsageLine() throws {
        let line: Substring = """
        {"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":500}},"timestamp":"2026-10-24T00:00:00Z"}
        """[...]
        let since = try XCTUnwrap(DateParsing.date("2026-10-01T00:00:00Z"))
        let usage = try XCTUnwrap(ClaudeCostEstimator.parseUsageLine(line, since: since))
        XCTAssertEqual(usage.model, "claude-sonnet-5")
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
    }

    func testCostEstimatorDropsLinesBeforeSince() throws {
        let line: Substring = """
        {"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":500}},"timestamp":"2026-01-01T00:00:00Z"}
        """[...]
        let since = try XCTUnwrap(DateParsing.date("2026-10-01T00:00:00Z"))
        XCTAssertNil(ClaudeCostEstimator.parseUsageLine(line, since: since))
    }

    func testCostEstimatorIgnoresNonAssistantLines() {
        let line: Substring = #"{"type":"user","message":{"usage":{"input_tokens":1}}}"#[...]
        XCTAssertNil(ClaudeCostEstimator.parseUsageLine(line, since: .distantPast))
    }

    func testCostEstimatorComputesSonnetRate() {
        let usage = ClaudeCostEstimator.Usage(
            model: "claude-sonnet-5", inputTokens: 1000, cacheWriteTokens: 2000, cacheReadTokens: 3000, outputTokens: 500
        )
        // (1000*3 + 2000*3.75 + 3000*0.30 + 500*15) / 1_000_000 = 18_900 / 1_000_000
        XCTAssertEqual(ClaudeCostEstimator.cost(for: usage), Decimal(string: "0.0189"))
    }

    func testCostEstimatorFallsBackToDefaultRateForUnknownModel() {
        let usage = ClaudeCostEstimator.Usage(model: "some-future-model", inputTokens: 0, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 1_000_000)
        XCTAssertEqual(ClaudeCostEstimator.cost(for: usage), ClaudeCostEstimator.defaultRate.output)
    }

    func testCostEstimatorAggregatesAcrossFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recentLine = #"{"type":"assistant","message":{"model":"claude-haiku-5","usage":{"input_tokens":1000000,"output_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))"}"#
        try recentLine.write(to: tmp.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let since = Date().addingTimeInterval(-3600)
        let estimate = try XCTUnwrap(ClaudeCostEstimator.estimate(projectsDir: tmp, since: since))
        XCTAssertEqual(estimate.totalUSD, ClaudeCostEstimator.rates.first(where: { $0.match == "haiku" })!.rate.input)
        XCTAssertEqual(estimate.inputTokens, 1_000_000)
    }

    // MARK: - CodexCostEstimator

    func testCodexCostEstimatorTracksActiveModelAndSumsPerTurnDeltas() throws {
        let since = try XCTUnwrap(DateParsing.date("2026-10-01T00:00:00Z"))
        let text = """
        {"timestamp":"2026-10-24T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol-mini"}}
        {"timestamp":"2026-10-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100}}}}
        {"timestamp":"2026-10-24T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"output_tokens":600},"last_token_usage":{"input_tokens":4000,"cached_input_tokens":0,"output_tokens":500}}}}
        """
        let usages = CodexCostEstimator.parseLines(text, since: since)
        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(usages.map(\.model), ["gpt-6.1-sol-mini", "gpt-6.1-sol-mini"])
        XCTAssertEqual(usages[1].inputTokens, 4000, "must sum the per-turn delta, not the cumulative total")
    }

    func testCodexCostEstimatorDropsEventsBeforeSince() throws {
        let since = try XCTUnwrap(DateParsing.date("2026-10-20T00:00:00Z"))
        let text = """
        {"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":100}}}}
        """
        XCTAssertTrue(CodexCostEstimator.parseLines(text, since: since).isEmpty)
    }

    func testCodexCostEstimatorComputesMiniRate() {
        let usage = CodexCostEstimator.Usage(model: "gpt-6.1-sol-mini", inputTokens: 1000, cachedInputTokens: 200, outputTokens: 500)
        // uncached input (800) * 0.25 + cached (200) * 0.025 + output (500) * 2 = 1205, / 1_000_000
        XCTAssertEqual(CodexCostEstimator.cost(for: usage), Decimal(string: "0.001205"))
    }

    func testCodexCostEstimatorFallsBackToDefaultRateForUnknownModel() {
        let usage = CodexCostEstimator.Usage(model: "some-future-codex-model", inputTokens: 0, cachedInputTokens: 0, outputTokens: 1_000_000)
        XCTAssertEqual(CodexCostEstimator.cost(for: usage), CodexCostEstimator.defaultRate.output)
    }

    // MARK: - WindowSchedule

    func testWindowIdleWhenWindowAbsent() {
        let snapshot = ProviderSnapshot(provider: .claude, state: .ok, windows: [])
        XCTAssertTrue(WindowSchedule.isSessionWindowIdle(snapshot, windowID: "claude-five_hour"))
    }

    func testWindowIdleWhenResetAlreadyPassed() {
        let snapshot = ProviderSnapshot(provider: .claude, state: .ok, windows: [
            QuotaWindow(id: "claude-five_hour", label: "Session (5h)", usedPercent: 40, resetsAt: Date().addingTimeInterval(-60)),
        ])
        XCTAssertTrue(WindowSchedule.isSessionWindowIdle(snapshot, windowID: "claude-five_hour"))
    }

    func testWindowNotIdleWhenResetInFuture() {
        let snapshot = ProviderSnapshot(provider: .claude, state: .ok, windows: [
            QuotaWindow(id: "claude-five_hour", label: "Session (5h)", usedPercent: 10, resetsAt: Date().addingTimeInterval(3600)),
        ])
        XCTAssertFalse(WindowSchedule.isSessionWindowIdle(snapshot, windowID: "claude-five_hour"))
    }

    func testWindowIdleWhenSnapshotMissingOrNotOK() {
        XCTAssertTrue(WindowSchedule.isSessionWindowIdle(nil, windowID: "claude-five_hour"))
        let errored = ProviderSnapshot(provider: .claude, state: .error, windows: [
            QuotaWindow(id: "claude-five_hour", label: "Session (5h)", usedPercent: 10, resetsAt: Date().addingTimeInterval(3600)),
        ])
        XCTAssertTrue(WindowSchedule.isSessionWindowIdle(errored, windowID: "claude-five_hour"))
    }

    // MARK: - ThresholdAlertTracker

    func testThresholdTrackerFiresOnceThenAdvances() {
        var tracker = ThresholdAlertTracker()
        let reset = Date().addingTimeInterval(3600)
        func snapshot(_ used: Double) -> ProviderSnapshot {
            ProviderSnapshot(provider: .codex, state: .ok,
                             windows: [QuotaWindow(id: "w1", label: "Weekly", usedPercent: used, resetsAt: reset)])
        }

        let first = tracker.crossings(for: [snapshot(85)], thresholds: [80, 95, 100])
        XCTAssertEqual(first.map(\.threshold), [80])

        // Still 85%: already notified at 80, shouldn't fire again.
        let second = tracker.crossings(for: [snapshot(85)], thresholds: [80, 95, 100])
        XCTAssertTrue(second.isEmpty)

        // Jumps straight to 97%: only the highest newly-reached threshold (95) fires.
        let third = tracker.crossings(for: [snapshot(97)], thresholds: [80, 95, 100])
        XCTAssertEqual(third.map(\.threshold), [95])
    }

    func testThresholdTrackerResetsOnNewWindow() {
        var tracker = ThresholdAlertTracker()
        let firstReset = Date().addingTimeInterval(3600)
        let secondReset = Date().addingTimeInterval(7200)

        _ = tracker.crossings(for: [ProviderSnapshot(provider: .codex, state: .ok,
            windows: [QuotaWindow(id: "w1", label: "Weekly", usedPercent: 85, resetsAt: firstReset)])], thresholds: [80])

        // Window rolled over (different resetsAt) and usage dropped: no crossing yet.
        let afterReset = tracker.crossings(for: [ProviderSnapshot(provider: .codex, state: .ok,
            windows: [QuotaWindow(id: "w1", label: "Weekly", usedPercent: 10, resetsAt: secondReset)])], thresholds: [80])
        XCTAssertTrue(afterReset.isEmpty)

        // Same fresh window crossing 80 again should fire, since state was cleared on rollover.
        let crossesAgain = tracker.crossings(for: [ProviderSnapshot(provider: .codex, state: .ok,
            windows: [QuotaWindow(id: "w1", label: "Weekly", usedPercent: 82, resetsAt: secondReset)])], thresholds: [80])
        XCTAssertEqual(crossesAgain.map(\.threshold), [80])
    }
}
