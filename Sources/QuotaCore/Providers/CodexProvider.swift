import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Codex CLI (ChatGPT plan) rate limits.
///
/// Primary: `GET https://chatgpt.com/backend-api/wham/usage` with the access token from `~/.codex/auth.json`
/// (or `$CODEX_HOME/auth.json`) and the `ChatGPT-Account-Id` header.
/// Fallback: the newest `~/.codex/sessions/**/rollout-*.jsonl` – Codex writes `rate_limits` into `token_count`
/// events after every turn, so this works offline and when the token is stale.
/// QuotaPulse never writes to auth.json (the Codex CLI owns it).
public struct CodexProvider: QuotaProvider {
    public let id = ProviderID.codex
    public init() {}

    var codexHome: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: h) }
        return Paths.inHome(".codex")
    }

    public func fetch() async -> ProviderSnapshot {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let authData = try? Data(contentsOf: authURL) else {
            return ProviderSnapshot(provider: id, state: .notConfigured, message: "Codex not logged in (no ~/.codex/auth.json).")
        }
        var oauthError: Error?
        do {
            let auth = try Self.parseAuth(authData)
            var req = HTTP.jsonRequest(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, bearer: auth.accessToken)
            if let acct = auth.accountId { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
            let data = try await HTTP.send(req)
            let parsed = try Self.parseUsage(data)
            let cost = await Self.estimateCostWithTimeout(sessionsDir: codexHome.appendingPathComponent("sessions"))
            return ProviderSnapshot(provider: id, state: .ok, windows: parsed.windows,
                                    plan: parsed.plan ?? auth.plan, account: auth.email, source: "oauth",
                                    costEstimate: cost)
        } catch {
            oauthError = error
        }
        // Fallback: local session logs.
        let sessionsDir = codexHome.appendingPathComponent("sessions")
        if let local = Self.latestSessionRateLimits(in: sessionsDir) {
            let cost = await Self.estimateCostWithTimeout(sessionsDir: sessionsDir)
            return ProviderSnapshot(provider: id, state: .ok, windows: local.windows,
                                    message: "From last Codex session (\(local.date.formatted(.relative(presentation: .named))))",
                                    source: "session-log", fetchedAt: Date(), costEstimate: cost)
        }
        return .failure(id, oauthError ?? QuotaError.other("No Codex usage data"))
    }

    /// Best-effort local cost estimate (last 7 days); never fails or blocks the quota fetch.
    private static func estimateCostWithTimeout(sessionsDir: URL) async -> CostEstimate? {
        await withTaskGroup(of: CostEstimate?.self) { group in
            group.addTask {
                guard Paths.exists(sessionsDir) else { return nil }
                let since = Date().addingTimeInterval(-7 * 86_400)
                return CodexCostEstimator.estimate(sessionsDir: sessionsDir, since: since)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: Auth

    struct Auth { var accessToken: String; var accountId: String?; var email: String?; var plan: String? }

    static func parseAuth(_ data: Data) throws -> Auth {
        let obj = try JSON.object(data)
        guard let tokens = obj["tokens"] as? JSONObject, let access = JSON.string(tokens["access_token"]) else {
            throw QuotaError.needsLogin("Codex is using an API key or has no ChatGPT login — run `codex login`.")
        }
        var accountId = JSON.string(tokens["account_id"])
        var email: String?
        var plan: String?
        if let idTok = JSON.string(tokens["id_token"]), let p = JWT.payload(idTok) {
            email = JSON.string(p["email"])
            if let a = p["https://api.openai.com/auth"] as? JSONObject {
                accountId = accountId ?? JSON.string(a["chatgpt_account_id"])
                plan = JSON.string(a["chatgpt_plan_type"])?.capitalized
            }
        }
        return Auth(accessToken: access, accountId: accountId, email: email, plan: plan)
    }

    // MARK: Parsing (pure, unit-tested)

    public static func parseUsage(_ data: Data) throws -> (windows: [QuotaWindow], plan: String?) {
        let obj = try JSON.object(data)
        guard let rl = obj["rate_limit"] as? JSONObject else { throw QuotaError.parse("No rate_limit in Codex response") }
        var windows: [QuotaWindow] = []
        for (key, fallbackLabel) in [("primary_window", "Session (5h)"), ("secondary_window", "Weekly")] {
            guard let w = rl[key] as? JSONObject, let used = JSON.double(w["used_percent"]) else { continue }
            let secs = JSON.seconds(w["limit_window_seconds"])
            var reset = DateParsing.date(w["reset_at"] ?? w["resets_at"])
            if reset == nil, let after = JSON.double(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(after) }
            windows.append(QuotaWindow(id: "codex-\(key)", label: label(forSeconds: secs) ?? fallbackLabel,
                                       usedPercent: used, resetsAt: reset, windowSeconds: secs))
        }
        if let extras = obj["additional_rate_limits"] as? [JSONObject] {
            for (i, extra) in extras.enumerated() {
                let name = JSON.string(extra["limit_name"]) ?? JSON.string(extra["name"]) ?? "Extra \(i + 1)"
                let inner = (extra["rate_limit"] as? JSONObject) ?? extra
                if let w = inner["primary_window"] as? JSONObject, let used = JSON.double(w["used_percent"]) {
                    windows.append(QuotaWindow(id: "codex-extra-\(i)", label: name, usedPercent: used,
                                               resetsAt: DateParsing.date(w["reset_at"]),
                                               windowSeconds: JSON.seconds(w["limit_window_seconds"])))
                }
            }
        }
        if windows.isEmpty { throw QuotaError.parse("Codex response had no usage windows") }
        return (windows, JSON.string(obj["plan_type"])?.capitalized)
    }

    static func label(forSeconds s: Int?) -> String? {
        guard let s else { return nil }
        switch s {
        case 17_000...19_000: return "Session (5h)"
        case 600_000...610_000: return "Weekly"
        default:
            let hours = s / 3600
            return hours >= 24 ? "\(hours / 24)-day" : "\(hours)h"
        }
    }

    /// Parses a single rollout JSONL line containing `rate_limits` (event_msg / token_count).
    public static func parseRateLimitsLine(_ line: Substring, fileDate: Date) -> [QuotaWindow]? {
        guard line.contains("rate_limits"), let data = line.data(using: .utf8),
              let obj = try? JSON.object(data) else { return nil }
        let payload = (obj["payload"] as? JSONObject) ?? obj
        guard let rl = payload["rate_limits"] as? JSONObject else { return nil }
        let eventDate = DateParsing.date(obj["timestamp"]) ?? fileDate
        var windows: [QuotaWindow] = []
        for (key, fallback) in [("primary", "Session (5h)"), ("secondary", "Weekly")] {
            guard let w = rl[key] as? JSONObject, let used = JSON.double(w["used_percent"]) else { continue }
            let secs = JSON.seconds(w["window_minutes"], multiplier: 60)
            var reset = DateParsing.date(w["resets_at"])
            if reset == nil, let inSecs = JSON.double(w["resets_in_seconds"]) { reset = eventDate.addingTimeInterval(inSecs) }
            // If the window already reset since the log line, the quota is fresh.
            let effectiveUsed = (reset.map { $0 < Date() } ?? false) ? 0 : used
            windows.append(QuotaWindow(id: "codex-\(key)", label: label(forSeconds: secs) ?? fallback,
                                       usedPercent: effectiveUsed, resetsAt: reset, windowSeconds: secs))
        }
        return windows.isEmpty ? nil : windows
    }

    /// Rollouts can contain very large tool outputs. Only read the last 2 MiB of
    /// each candidate; a normal token_count event is near the end of an active session.
    private static func sessionTail(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let budget: UInt64 = 2 * 1024 * 1024
            let start = end > budget ? end - budget : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(budget)) else { return nil }
            // Drop the partial first line, including any split UTF-8 code point.
            if start > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                return String(decoding: data[data.index(after: newline)...], as: UTF8.self)
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    static func latestSessionRateLimits(in dir: URL) -> (windows: [QuotaWindow], date: Date)? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, d))
        }
        for (url, date) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let text = sessionTail(at: url) else { continue }
            for line in text.split(separator: "\n").reversed() {
                if let w = parseRateLimitsLine(line, fileDate: date) { return (w, date) }
            }
        }
        return nil
    }
}
