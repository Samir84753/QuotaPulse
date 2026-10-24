import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude Code subscription limits.
///
/// Credentials: macOS Keychain item "Claude Code-credentials" (read via `/usr/bin/security`, the user sees a
/// one-time "allow" prompt), falling back to `~/.claude/.credentials.json`.
/// Endpoint: `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`.
///
/// QuotaPulse never refreshes the Claude token itself: refreshing rotates the refresh token and would log the
/// user out of Claude Code. When the token is expired we ask the user to run `claude` once.
public struct ClaudeProvider: QuotaProvider {
    public let id = ProviderID.claude
    public init() {}

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
    }

    public func fetch() async -> ProviderSnapshot {
        do {
            let creds = try await loadCredentials()
            if let exp = creds.expiresAt, exp < Date() {
                throw QuotaError.needsLogin("Claude token expired — run `claude` once to refresh it.")
            }
            var req = HTTP.jsonRequest(URL(string: "https://api.anthropic.com/api/oauth/usage")!, bearer: creds.accessToken)
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let data = try await HTTP.send(req)
            let windows = try Self.parseUsage(data)
            let cost = await Self.estimateCostWithTimeout()
            return ProviderSnapshot(
                provider: id, state: .ok, windows: windows,
                plan: creds.subscriptionType.map { $0.capitalized },
                source: "oauth",
                costEstimate: cost
            )
        } catch {
            return .failure(id, error)
        }
    }

    /// Best-effort local cost estimate (last 7 days); never fails or blocks the quota fetch.
    private static func estimateCostWithTimeout() async -> CostEstimate? {
        await withTaskGroup(of: CostEstimate?.self) { group in
            group.addTask {
                let dir = Paths.inHome(".claude/projects")
                guard Paths.exists(dir) else { return nil }
                let since = Date().addingTimeInterval(-7 * 86_400)
                return ClaudeCostEstimator.estimate(projectsDir: dir, since: since)
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

    // MARK: Parsing (pure, unit-tested)

    public static func parseUsage(_ data: Data) throws -> [QuotaWindow] {
        let obj = try JSON.object(data)
        let map: [(key: String, label: String, seconds: Int)] = [
            ("five_hour", "Session (5h)", 18_000),
            ("seven_day", "Weekly", 604_800),
            ("seven_day_opus", "Weekly · Opus", 604_800),
            ("seven_day_sonnet", "Weekly · Sonnet", 604_800),
        ]
        var windows: [QuotaWindow] = []
        for entry in map {
            guard let w = obj[entry.key] as? JSONObject, let util = JSON.double(w["utilization"]) else { continue }
            // `utilization` is a percentage (0...100).
            windows.append(QuotaWindow(
                id: "claude-\(entry.key)", label: entry.label, usedPercent: util,
                resetsAt: DateParsing.date(w["resets_at"]), windowSeconds: entry.seconds
            ))
        }
        // Newer responses also expose normalized limits. Use these only when a legacy
        // window is absent; both representations are commonly returned together.
        if let limits = obj["limits"] as? [JSONObject] {
            let kinds = ["five_hour": "session", "seven_day": "weekly_all"]
            for entry in map {
                guard !windows.contains(where: { $0.id == "claude-\(entry.key)" }),
                      let kind = kinds[entry.key],
                      let limit = limits.first(where: {
                          JSON.string($0["kind"]) == kind && ($0["scope"] == nil || $0["scope"] is NSNull)
                      }), let percent = JSON.double(limit["percent"]) else { continue }
                // is_active describes the currently binding limit, not whether the window exists.
                windows.append(QuotaWindow(
                    id: "claude-\(entry.key)", label: entry.label, usedPercent: percent,
                    resetsAt: DateParsing.date(limit["resets_at"]), windowSeconds: entry.seconds
                ))
            }
        }
        if windows.isEmpty { throw QuotaError.parse("No Claude limit windows in response (free plan?)") }
        return windows
    }

    static func parseCredentials(_ data: Data) throws -> Credentials {
        let obj = try JSON.object(data)
        let oauth = (obj["claudeAiOauth"] as? JSONObject) ?? obj
        guard let token = JSON.string(oauth["accessToken"]) ?? JSON.string(oauth["access_token"]) else {
            throw QuotaError.needsLogin("Claude credentials contain no OAuth token — run `claude` and /login.")
        }
        return Credentials(
            accessToken: token,
            expiresAt: DateParsing.date(oauth["expiresAt"]),
            subscriptionType: JSON.string(oauth["subscriptionType"])
        )
    }

    // MARK: Credential loading

    func loadCredentials() async throws -> Credentials {
        if let env = ProcessInfo.processInfo.environment["QUOTAPULSE_CLAUDE_TOKEN"] {
            return Credentials(accessToken: env, expiresAt: nil, subscriptionType: nil)
        }
        #if os(macOS)
        let r = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 30)
        if r.status == 0, let data = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let creds = try? Self.parseCredentials(data) {
            return creds
        }
        #endif
        let file = Paths.inHome(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) {
            return try Self.parseCredentials(data)
        }
        throw QuotaError.notConfigured("Claude Code not logged in (no Keychain item or ~/.claude/.credentials.json).")
    }
}
