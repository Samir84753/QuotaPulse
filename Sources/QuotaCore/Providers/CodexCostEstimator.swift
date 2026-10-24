import Foundation

/// Estimates $ spend for Codex from local session transcripts (`~/.codex/sessions/**/rollout-*.jsonl`).
///
/// Same caveat as `ClaudeCostEstimator`: the ChatGPT usage endpoint (used by `CodexProvider`) only
/// reports % consumed of a flat-rate plan window, never a dollar figure. This is a local, best-effort
/// approximation using public per-model-family token pricing; the rate table can drift out of date as
/// OpenAI changes pricing or ships new model ids, and an unrecognized model falls back to a default
/// rate. QuotaPulse only ever reads these transcripts.
public enum CodexCostEstimator {
    struct Rate {
        var input: Decimal        // $ / 1M input tokens
        var cachedInput: Decimal  // $ / 1M cached input tokens (prompt-cache discount)
        var output: Decimal       // $ / 1M output tokens (includes reasoning tokens)
    }

    /// Matched by substring against the model id in `turn_context` events (e.g. "gpt-6.1-sol",
    /// "gpt-5-codex-mini"). Order matters: more specific tiers are checked before the general "gpt".
    static let rates: [(match: String, rate: Rate)] = [
        ("nano", Rate(input: 0.05, cachedInput: 0.005, output: 0.40)),
        ("mini", Rate(input: 0.25, cachedInput: 0.025, output: 2)),
        ("gpt", Rate(input: 1.25, cachedInput: 0.125, output: 10)),
    ]
    static let defaultRate = Rate(input: 1.25, cachedInput: 0.125, output: 10)

    static func rate(forModel model: String) -> Rate {
        let lower = model.lowercased()
        return rates.first(where: { lower.contains($0.match) })?.rate ?? defaultRate
    }

    public struct Usage: Equatable {
        public var model: String
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var outputTokens: Int
    }

    static func cost(for usage: Usage) -> Decimal {
        let r = rate(forModel: usage.model)
        let perToken = Decimal(1) / Decimal(1_000_000)
        let uncachedInput = max(0, usage.inputTokens - usage.cachedInputTokens)
        return (Decimal(uncachedInput) * r.input
              + Decimal(usage.cachedInputTokens) * r.cachedInput
              + Decimal(usage.outputTokens) * r.output) * perToken
    }

    /// Scans one rollout file's lines for per-turn usage since `since`. Tracks the active model from
    /// `turn_context` events (sessions can in principle switch models mid-session) and sums each
    /// `token_count` event's `last_token_usage` (a per-turn delta) rather than `total_token_usage`
    /// (a running session total, which would massively over-count if summed across events).
    static func parseLines(_ text: String, since: Date) -> [Usage] {
        var currentModel = "gpt"
        var usages: [Usage] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let obj = try? JSON.object(data) else { continue }
            if JSON.string(obj["type"]) == "turn_context",
               let payload = obj["payload"] as? JSONObject, let model = JSON.string(payload["model"]) {
                currentModel = model
                continue
            }
            guard JSON.string(obj["type"]) == "event_msg", let payload = obj["payload"] as? JSONObject,
                  JSON.string(payload["type"]) == "token_count", let info = payload["info"] as? JSONObject,
                  let last = info["last_token_usage"] as? JSONObject else { continue }
            if let ts = DateParsing.date(obj["timestamp"]), ts < since { continue }
            usages.append(Usage(
                model: currentModel,
                inputTokens: Int(JSON.double(last["input_tokens"]) ?? 0),
                cachedInputTokens: Int(JSON.double(last["cached_input_tokens"]) ?? 0),
                outputTokens: Int(JSON.double(last["output_tokens"]) ?? 0)
            ))
        }
        return usages
    }

    /// Scans the most recently modified rollout files under `sessionsDir` for usage since `since`,
    /// bounded to `maxFiles` files for performance.
    public static func estimate(sessionsDir: URL, since: Date, maxFiles: Int = 40) -> CostEstimate? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
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
            for usage in parseLines(text, since: since) {
                totalCost += cost(for: usage)
                totalInput += usage.inputTokens
                totalOutput += usage.outputTokens
            }
        }
        guard totalInput > 0 || totalOutput > 0 else { return nil }
        return CostEstimate(totalUSD: totalCost, periodStart: since, inputTokens: totalInput, outputTokens: totalOutput)
    }
}
