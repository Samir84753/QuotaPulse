import Foundation

/// Estimates $ spend for Claude Code from local session transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Anthropic's OAuth usage endpoint (used by `ClaudeProvider`) only reports % consumed of a flat-rate
/// plan window — it never returns a dollar figure. This estimator is a local, best-effort approximation
/// using public per-model-family token pricing; it is **not** an authoritative bill and the rate table
/// can drift out of date as Anthropic changes pricing. QuotaPulse only ever reads these transcripts.
public enum ClaudeCostEstimator {
    struct Rate {
        var input: Decimal       // $ / 1M input tokens
        var cacheWrite: Decimal  // $ / 1M tokens written to the prompt cache
        var cacheRead: Decimal   // $ / 1M tokens read from the prompt cache
        var output: Decimal      // $ / 1M output tokens
    }

    /// Representative published Anthropic per-model-family pricing, matched by substring against
    /// whatever model id appears in the transcript (e.g. "claude-sonnet-5", "claude-opus-4-1").
    static let rates: [(match: String, rate: Rate)] = [
        ("opus", Rate(input: 15, cacheWrite: 18.75, cacheRead: 1.50, output: 75)),
        ("sonnet", Rate(input: 3, cacheWrite: 3.75, cacheRead: 0.30, output: 15)),
        ("haiku", Rate(input: 0.80, cacheWrite: 1.00, cacheRead: 0.08, output: 4)),
    ]
    static let defaultRate = Rate(input: 3, cacheWrite: 3.75, cacheRead: 0.30, output: 15)

    static func rate(forModel model: String) -> Rate {
        let lower = model.lowercased()
        return rates.first(where: { lower.contains($0.match) })?.rate ?? defaultRate
    }

    public struct Usage: Equatable {
        public var model: String
        public var inputTokens: Int
        public var cacheWriteTokens: Int
        public var cacheReadTokens: Int
        public var outputTokens: Int
    }

    /// Parses one JSONL transcript line into token usage, if it's an assistant message with a
    /// `usage` block timestamped on/after `since`. Returns nil for every other line (tool calls,
    /// user turns, sidecar metadata, etc.) without throwing — transcripts are not a strict schema.
    public static func parseUsageLine(_ line: Substring, since: Date) -> Usage? {
        guard line.contains("\"usage\""), let data = line.data(using: .utf8),
              let obj = try? JSON.object(data), JSON.string(obj["type"]) == "assistant",
              let message = obj["message"] as? JSONObject, let usage = message["usage"] as? JSONObject,
              let model = JSON.string(message["model"]) else { return nil }
        if let ts = DateParsing.date(obj["timestamp"]), ts < since { return nil }
        return Usage(
            model: model,
            inputTokens: Int(JSON.double(usage["input_tokens"]) ?? 0),
            cacheWriteTokens: Int(JSON.double(usage["cache_creation_input_tokens"]) ?? 0),
            cacheReadTokens: Int(JSON.double(usage["cache_read_input_tokens"]) ?? 0),
            outputTokens: Int(JSON.double(usage["output_tokens"]) ?? 0)
        )
    }

    static func cost(for usage: Usage) -> Decimal {
        let r = rate(forModel: usage.model)
        let perToken = Decimal(1) / Decimal(1_000_000)
        return (Decimal(usage.inputTokens) * r.input
              + Decimal(usage.cacheWriteTokens) * r.cacheWrite
              + Decimal(usage.cacheReadTokens) * r.cacheRead
              + Decimal(usage.outputTokens) * r.output) * perToken
    }

    /// Scans the most recently modified session transcripts under `projectsDir` for usage since
    /// `since`, bounded to `maxFiles` files for performance (a file modified before `since` cannot
    /// contain in-range turns, so this naturally stays small for a "last 7 days" window).
    public static func estimate(projectsDir: URL, since: Date, maxFiles: Int = 60) -> CostEstimate? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified >= since else { continue }
            files.append((url, modified))
        }
        guard !files.isEmpty else { return nil }

        var totalCost = Decimal(0)
        var totalInput = 0
        var totalOutput = 0
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(maxFiles) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let usage = parseUsageLine(line, since: since) else { continue }
                totalCost += cost(for: usage)
                totalInput += usage.inputTokens + usage.cacheWriteTokens + usage.cacheReadTokens
                totalOutput += usage.outputTokens
            }
        }
        guard totalInput > 0 || totalOutput > 0 else { return nil }
        return CostEstimate(totalUSD: totalCost, periodStart: since, inputTokens: totalInput, outputTokens: totalOutput)
    }
}
