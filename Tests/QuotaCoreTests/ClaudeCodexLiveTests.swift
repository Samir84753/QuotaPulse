import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodexLiveTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testClaudeLiveUsageAndLimitsOnlyResponse() throws {
        let data = try fixture("claude_usage_live.json")
        let windows = try ClaudeProvider.parseUsage(data)
        XCTAssertEqual(windows.map(\.label), ["Session (5h)", "Weekly"])
        XCTAssertEqual(windows.map(\.usedPercent), [13, 3])
        XCTAssertTrue(windows.allSatisfy { $0.resetsAt != nil })

        let obj = try JSON.object(data)
        let limitsOnly = try JSONSerialization.data(withJSONObject: ["limits": try XCTUnwrap(obj["limits"])])
        let fallback = try ClaudeProvider.parseUsage(limitsOnly)
        XCTAssertEqual(fallback.map(\.id), windows.map(\.id))
        XCTAssertEqual(fallback.map(\.usedPercent), [13, 3], "is_active=false still describes weekly usage")
        XCTAssertEqual(fallback.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertTrue(fallback.allSatisfy { $0.resetsAt != nil })
    }

    func testClaudeModelWindowsAndUnknownMetadata() throws {
        let data = Data(#"{"seven_day_opus":{"utilization":42,"resets_at":"2030-01-01T00:00:00Z"},"seven_day_sonnet":{"utilization":17},"limits":[{"kind":"unrecognized","percent":99}],"extra_usage":{"utilization":50}}"#.utf8)
        let windows = try ClaudeProvider.parseUsage(data)
        XCTAssertEqual(windows.map(\.label), ["Weekly · Opus", "Weekly · Sonnet"])
        XCTAssertEqual(windows.map(\.usedPercent), [42, 17])
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(Data(#"{"limits":[{"kind":"unknown","percent":99}]}"#.utf8)))
    }

    func testCodexLiveUsage() throws {
        let parsed = try CodexProvider.parseUsage(fixture("codex_usage_live.json"))
        XCTAssertEqual(parsed.plan, "Plus")
        XCTAssertEqual(parsed.windows.map(\.label), ["Session (5h)", "Weekly"])
        XCTAssertEqual(parsed.windows.map(\.usedPercent), [3, 0])
        XCTAssertEqual(parsed.windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertEqual(parsed.windows.first?.resetsAt?.timeIntervalSince1970, 1_792_838_973)
    }

    func testCodexAuthAccountAndJWTPlan() throws {
        let claims: JSONObject = ["email": "fixture@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "fake-claim-account", "chatgpt_plan_type": "plus"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var tokens = ["access_token": "fake-access-token", "account_id": "fake-explicit-account", "id_token": "fake.\(payload).fake"]
        func parse() throws -> CodexProvider.Auth {
            try CodexProvider.parseAuth(JSONSerialization.data(withJSONObject: ["tokens": tokens]))
        }
        let auth = try parse()
        XCTAssertEqual(auth.accessToken, "fake-access-token")
        XCTAssertEqual(auth.accountId, "fake-explicit-account")
        XCTAssertEqual(auth.email, "fixture@example.com")
        XCTAssertEqual(auth.plan, "Plus")
        tokens.removeValue(forKey: "account_id")
        XCTAssertEqual(try parse().accountId, "fake-claim-account")
        XCTAssertThrowsError(try CodexProvider.parseAuth(Data(#"{"OPENAI_API_KEY":"fake-api-key"}"#.utf8)))
    }

    func testCodexLiveSessionLine() throws {
        // Real response timestamps are fixed; move resets into the future so this fixture never ages out.
        var obj = try JSON.object(fixture("codex_rollout_live.jsonl"))
        var payload = try XCTUnwrap(obj["payload"] as? JSONObject)
        var limits = try XCTUnwrap(payload["rate_limits"] as? JSONObject)
        for key in ["primary", "secondary"] {
            var window = try XCTUnwrap(limits[key] as? JSONObject)
            window["resets_at"] = Date().addingTimeInterval(3600).timeIntervalSince1970
            limits[key] = window
        }
        payload["rate_limits"] = limits
        obj["payload"] = payload
        let line = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let windows = try XCTUnwrap(CodexProvider.parseRateLimitsLine(line[...], fileDate: Date()))
        XCTAssertEqual(windows.map(\.label), ["Session (5h)", "Weekly"])
        XCTAssertEqual(windows.map(\.usedPercent), [2, 0])
    }

    func testSessionScanOnlyNewestFiveRolloutsAndReadsTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"payload":{"rate_limits":{"primary":{"used_percent":23,"window_minutes":300}}}}"#
        for i in 0..<6 {
            let file = dir.appendingPathComponent("rollout-\(i).jsonl")
            try Data((i == 0 ? line : "{}\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i))], ofItemAtPath: file.path)
        }
        // A newer unrelated JSONL must not displace one of the five rollouts.
        try Data(line.utf8).write(to: dir.appendingPathComponent("unrelated.jsonl"))
        XCTAssertNil(CodexProvider.latestSessionRateLimits(in: dir), "The sixth rollout must not be read")
        let newest = dir.appendingPathComponent("rollout-5.jsonl")
        var content = Data(repeating: 120, count: 3 * 1024 * 1024)
        content.append(Data(("\n" + line + "\n{}").utf8))
        try content.write(to: newest)
        let result = try XCTUnwrap(CodexProvider.latestSessionRateLimits(in: dir))
        XCTAssertEqual(result.windows.first?.usedPercent, 23)
        XCTAssertEqual(result.windows.first?.label, "Session (5h)")
    }
}
