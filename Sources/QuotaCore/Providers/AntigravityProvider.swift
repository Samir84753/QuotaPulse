import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google Antigravity (app / IDE / `agy`) per-model quotas, read from the running local language server.
///
/// 1. `ps -ax -o pid=,command=` → find `language_server*` or `agy` processes.
/// 2. `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` → candidate ports (+ `--extension_server_port` for HTTP).
/// 3. `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` (preferred)
///    falling back to `GetUserStatus` → `cascadeModelConfigData.clientModelConfigs[].quotaInfo`.
///    Headers: `X-Codeium-Csrf-Token`, `Connect-Protocol-Version: 1`; self-signed TLS accepted for loopback only.
/// Total Antigravity fetch completes < 6 s even when nothing answers.
public struct AntigravityProvider: QuotaProvider {
    public let id = ProviderID.antigravity
    public init() {}

    static let service = "exa.language_server_pb.LanguageServerService"

    public struct ServerProcess: Sendable, Equatable {
        public var pid: Int
        public var csrfToken: String?
        public var extensionPort: Int?
        public var extensionCsrfToken: String?

        public init(pid: Int, csrfToken: String? = nil, extensionPort: Int? = nil, extensionCsrfToken: String? = nil) {
            self.pid = pid
            self.csrfToken = csrfToken
            self.extensionPort = extensionPort
            self.extensionCsrfToken = extensionCsrfToken
        }
    }

    public func fetch() async -> ProviderSnapshot {
        #if os(macOS)
        // Hard timeout limit: total fetch must finish < 6s
        return await withTaskGroup(of: ProviderSnapshot.self) { group in
            group.addTask {
                await self.performFetch()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_500_000_000)
                return ProviderSnapshot(provider: self.id, state: .error,
                                        message: "Antigravity language server request timed out (<6s).")
            }
            let result = await group.next() ?? ProviderSnapshot(provider: self.id, state: .error, message: "Antigravity request cancelled.")
            group.cancelAll()
            return result
        }
        #else
        return ProviderSnapshot(provider: id, state: .notConfigured, message: "Antigravity is macOS-only")
        #endif
    }

    private func performFetch() async -> ProviderSnapshot {
        #if os(macOS)
        // Fast path: if environment specifies ANTIGRAVITY_LS_ADDRESS (e.g. localhost:63433)
        let envToken = ProcessInfo.processInfo.environment["ANTIGRAVITY_CSRF_TOKEN"]
        if let envAddr = ProcessInfo.processInfo.environment["ANTIGRAVITY_LS_ADDRESS"] {
            let parts = envAddr.split(separator: ":")
            if let port = parts.last.flatMap({ Int($0) }) {
                for scheme in ["http", "https"] {
                    if Task.isCancelled { break }
                    if let snap = await tryTarget(scheme: scheme, port: port, token: envToken) {
                        return snap
                    }
                }
            }
        }

        let ps = await Shell.run("/bin/ps", ["-ax", "-o", "pid=,command="], timeout: 1.5)
        let servers = Self.parseProcessList(ps.stdout)
        guard !servers.isEmpty else {
            let installed = Paths.exists(Paths.inHome(".antigravity"))
                || Paths.exists(Paths.inHome(".gemini/antigravity-cli"))
                || Paths.exists(URL(fileURLWithPath: "/Applications/Antigravity.app"))
                || FileManager.default.fileExists(atPath: Paths.inHome(".local/bin/agy").path)
            return ProviderSnapshot(provider: id, state: .notConfigured,
                                    message: installed ? "Open Antigravity (or run `agy`) to read its quota." : "Antigravity not installed.")
        }

        var lastError: Error = QuotaError.other("Antigravity language server did not answer")
        for server in servers {
            if Task.isCancelled { break }
            let lsof = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(server.pid)"], timeout: 1.0)
            let ports = Self.parseListeningPorts(lsof.stdout)
            var targets: [(scheme: String, port: Int, token: String?)] = []
            for p in ports {
                targets.append(("https", p, server.csrfToken))
                targets.append(("http", p, server.csrfToken))
            }
            if let p = server.extensionPort {
                targets.append(("http", p, server.extensionCsrfToken ?? server.csrfToken))
            }

            for t in targets {
                if Task.isCancelled { break }
                if let snap = await tryTarget(scheme: t.scheme, port: t.port, token: t.token, recordError: { lastError = $0 }) {
                    return snap
                }
            }
        }
        return .failure(id, lastError)
        #else
        return ProviderSnapshot(provider: id, state: .notConfigured, message: "Antigravity is macOS-only")
        #endif
    }

    private func tryTarget(scheme: String, port: Int, token: String?, recordError: ((Error) -> Void)? = nil) async -> ProviderSnapshot? {
        // Preferred: RetrieveUserQuotaSummary
        do {
            let quotaData = try await call(scheme: scheme, port: port, method: "RetrieveUserQuotaSummary", token: token)
            let windows = try Self.parseUserQuotaSummary(quotaData)
            var email: String?
            var plan: String?
            if let statusData = try? await call(scheme: scheme, port: port, method: "GetUserStatus", token: token),
               let statusParsed = try? Self.parseUserStatus(statusData) {
                email = statusParsed.email
                plan = statusParsed.plan
            }
            return ProviderSnapshot(provider: id, state: .ok, windows: windows, plan: plan,
                                    account: email, source: "local-server")
        } catch {
            recordError?(error)
        }

        // Fallback: GetUserStatus
        do {
            let statusData = try await call(scheme: scheme, port: port, method: "GetUserStatus", token: token)
            let parsed = try Self.parseUserStatus(statusData)
            return ProviderSnapshot(provider: id, state: .ok, windows: parsed.windows, plan: parsed.plan,
                                    account: parsed.email, source: "local-server")
        } catch {
            recordError?(error)
        }
        return nil
    }

    func call(scheme: String, port: Int, method: String, token: String?) async throws -> Data {
        try Task.checkCancellation()
        guard (1...65535).contains(port), ["http", "https"].contains(scheme),
              let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.service)/\(method)") else {
            throw QuotaError.other("Invalid Antigravity loopback address")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 1.0
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token, !token.isEmpty { r.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en", "ideVersion": "unknown"],
        ])
        let session = (scheme == "https") ? LoopbackTLS.session : LoopbackHTTP.session
        return try await HTTP.send(r, session: session)
    }

    // MARK: Parsing (pure, unit-tested)

    public static func parseProcessList(_ text: String) -> [ServerProcess] {
        let envToken = ProcessInfo.processInfo.environment["ANTIGRAVITY_CSRF_TOKEN"]
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let pid = parts.first.flatMap({ Int($0) }), parts.count > 1 else { return nil }

            let exec = parts[1]
            let execName = URL(fileURLWithPath: exec).lastPathComponent.lowercased()

            let isLanguageServer = (lower.contains("language_server") || lower.contains("language-server")) && lower.contains("antigravity")
            let isAgyCli = execName == "agy" || execName == "antigravity"

            guard isLanguageServer || isAgyCli else { return nil }

            func flag(_ name: String) -> String? {
                for (i, p) in parts.enumerated() {
                    if p == name, i + 1 < parts.count { return parts[i + 1] }
                    if p.hasPrefix(name + "=") { return String(p.dropFirst(name.count + 1)) }
                }
                return nil
            }

            let csrf = flag("--csrf_token") ?? (isAgyCli ? envToken : nil)
            if isLanguageServer && csrf == nil { return nil }

            return ServerProcess(pid: pid, csrfToken: csrf,
                                 extensionPort: flag("--extension_server_port").flatMap { Int($0) },
                                 extensionCsrfToken: flag("--extension_server_csrf_token"))
        }
    }

    public static func parseListeningPorts(_ lsof: String) -> [Int] {
        var ports: [Int] = []
        for line in lsof.split(separator: "\n") where line.contains("LISTEN") {
            // e.g. "language_ 123 me 12u IPv4 0x... 0t0 TCP 127.0.0.1:53412 (LISTEN)"
            guard let tcp = line.split(separator: " ").first(where: { $0.contains(":") && !$0.hasPrefix("0x") }),
                  let port = tcp.split(separator: ":").last.flatMap({ Int($0) }) else { continue }
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    public static func parseUserQuotaSummary(_ data: Data) throws -> [QuotaWindow] {
        let o = try JSON.object(data)
        let resp = (o["response"] as? JSONObject) ?? o
        guard let groups = resp["groups"] as? [JSONObject], !groups.isEmpty else {
            throw QuotaError.parse("No groups in RetrieveUserQuotaSummary response")
        }
        var windows: [QuotaWindow] = []
        for (gIdx, group) in groups.enumerated() {
            let groupName = JSON.string(group["displayName"])
            guard let buckets = group["buckets"] as? [JSONObject] else { continue }
            for (bIdx, bucket) in buckets.enumerated() {
                guard let frac = JSON.double(bucket["remainingFraction"]) ??
                                (bucket["remaining"] as? JSONObject).flatMap({ JSON.double($0["remainingFraction"]) }) else {
                    continue
                }
                let bucketId = JSON.string(bucket["bucketId"]) ?? "\(gIdx)-\(bIdx)"
                let bucketName = JSON.string(bucket["displayName"])
                let windowName = JSON.string(bucket["window"])

                let label = formatBucketLabel(group: groupName, bucket: bucketName, window: windowName)
                let windowSec: Int?
                if let windowName {
                    if windowName.contains("5h") { windowSec = 18_000 }
                    else if windowName.contains("weekly") { windowSec = 604_800 }
                    else { windowSec = nil }
                } else {
                    windowSec = nil
                }

                windows.append(QuotaWindow(
                    id: "agy-\(bucketId)",
                    label: label,
                    usedPercent: (1 - frac) * 100,
                    resetsAt: DateParsing.date(bucket["resetTime"]),
                    windowSeconds: windowSec
                ))
            }
        }
        if windows.isEmpty {
            throw QuotaError.parse("No valid quota buckets found in RetrieveUserQuotaSummary response")
        }
        return windows
    }

    public static func formatBucketLabel(group: String?, bucket: String?, window: String?) -> String {
        let g = (group ?? "")
            .replacingOccurrences(of: " Models", with: "")
            .replacingOccurrences(of: " models", with: "")
            .trimmingCharacters(in: .whitespaces)
        let w: String
        if let window, !window.isEmpty {
            if window.lowercased() == "5h" { w = "5-Hour" }
            else if window.lowercased() == "weekly" { w = "Weekly" }
            else { w = window.capitalized }
        } else {
            w = (bucket ?? "Quota")
                .replacingOccurrences(of: " Limit Remaining", with: "")
                .replacingOccurrences(of: " Limit", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        if !g.isEmpty && !w.isEmpty {
            return "\(g) · \(w)"
        } else if !g.isEmpty {
            return g
        } else {
            return bucket ?? "Quota"
        }
    }

    public static func parseUserStatus(_ data: Data) throws -> (windows: [QuotaWindow], email: String?, plan: String?) {
        let o = try JSON.object(data)
        guard let status = o["userStatus"] as? JSONObject else { throw QuotaError.parse("No userStatus in Antigravity response") }
        let email = JSON.string(status["email"])
        var plan: String?
        if let info = (status["planStatus"] as? JSONObject)?["planInfo"] as? JSONObject {
            plan = ["planDisplayName", "displayName", "productName", "planName"].lazy.compactMap { JSON.string(info[$0]) }.first
        }
        plan = plan ?? JSON.string((status["userTier"] as? JSONObject)?["name"])
        let configs = ((status["cascadeModelConfigData"] as? JSONObject)?["clientModelConfigs"] as? [JSONObject]) ?? []
        var windows: [QuotaWindow] = []
        for c in configs {
            guard let q = c["quotaInfo"] as? JSONObject, let frac = JSON.double(q["remainingFraction"]) else { continue }
            let label = JSON.string(c["label"]) ?? JSON.string((c["modelOrAlias"] as? JSONObject)?["model"]) ?? "Model"
            windows.append(QuotaWindow(id: "agy-\(label)", label: label, usedPercent: (1 - frac) * 100,
                                       resetsAt: DateParsing.date(q["resetTime"])))
        }
        if windows.isEmpty { throw QuotaError.parse("Antigravity returned no model quotas") }
        return (windows, email, plan)
    }
}

/// URLSession for plain HTTP loopback calls with 1.0s timeout.
final class LoopbackHTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.0
        cfg.timeoutIntervalForResource = 1.5
        return URLSession(configuration: cfg)
    }()
}

/// URLSession that trusts self-signed certificates **only** for 127.0.0.1 / localhost.
final class LoopbackTLS: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.0
        cfg.timeoutIntervalForResource = 1.5
        return URLSession(configuration: cfg, delegate: LoopbackTLS(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           host == "127.0.0.1" || host == "localhost",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}
