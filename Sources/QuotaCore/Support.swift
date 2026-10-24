import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Loose JSON access (provider APIs are internal and drift; be tolerant)

public typealias JSONObject = [String: Any]

public enum JSON {
    public static func object(_ data: Data) throws -> JSONObject {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw QuotaError.parse("Expected a JSON object")
        }
        return obj
    }

    public static func double(_ v: Any?) -> Double? {
        let value: Double?
        switch v {
        case let d as Double: value = d
        case let i as Int: value = Double(i)
        case let n as NSNumber: value = n.doubleValue
        case let s as String: value = Double(s)
        default: value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    static func seconds(_ value: Any?, multiplier: Double = 1) -> Int? {
        guard let number = double(value) else { return nil }
        return Int(exactly: (number * multiplier).rounded(.towardZero))
    }

    public static func string(_ v: Any?) -> String? {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}

// MARK: - Dates

public enum DateParsing {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts ISO-8601 strings (with/without fractional seconds, any precision) or epoch seconds/millis.
    public static func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let d = isoFrac.date(from: s) ?? iso.date(from: s) { return d }
            // Trim sub-millisecond precision e.g. 2026-10-24T10:00:00.123456789Z
            if let dot = s.firstIndex(of: "."), let z = s.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), z > dot {
                let frac = s[s.index(after: dot)..<z].prefix(3)
                let trimmed = String(s[..<dot]) + "." + frac + String(s[z...])
                if let d = isoFrac.date(from: trimmed) { return d }
            }
            if let n = Double(s) { return epoch(n) }
            return nil
        }
        if let n = JSON.double(v) { return epoch(n) }
        return nil
    }

    static func epoch(_ n: Double) -> Date? {
        guard n.isFinite, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }
}

// MARK: - Files

public enum Paths {
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["QUOTAPULSE_HOME"] { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func inHome(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - HTTP

public enum HTTP {
    public static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    public static func send(_ request: URLRequest, session: URLSession = HTTP.session) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.other("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin("Login rejected (HTTP \(http.statusCode)). Re-authenticate in the CLI.")
            }
            throw QuotaError.http(http.statusCode, body)
        }
        return data
    }

    public static func jsonRequest(_ url: URL, method: String = "GET", bearer: String? = nil, body: JSONObject? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("QuotaPulse/1.0", forHTTPHeaderField: "User-Agent")
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }
}

// MARK: - Subprocess

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Drains both pipes without blocking. Cancellation and timeout kill the direct child;
    /// inherited pipes held by descendants cannot keep this operation alive.
    public static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 10, workingDirectory: URL? = nil) async -> Result {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: launchPath)
                    p.arguments = args
                    if let workingDirectory { p.currentDirectoryURL = workingDirectory }
                    let out = Pipe(), err = Pipe()
                    p.standardOutput = out
                    p.standardError = err
                    defer {
                        try? out.fileHandleForReading.close()
                        try? err.fileHandleForReading.close()
                    }
                    guard !cancellation.isCancelled else {
                        cont.resume(returning: Result(status: -1, stdout: "", stderr: "Cancelled"))
                        return
                    }
                    do { try p.run() } catch {
                        cont.resume(returning: Result(status: -1, stdout: "", stderr: "Could not launch subprocess"))
                        return
                    }
                    let descriptors = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
                    for fd in descriptors { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
                    let duration = timeout.isFinite ? max(0, timeout) : 10
                    let deadline = ProcessInfo.processInfo.systemUptime + duration
                    var output = [Data(), Data()]
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    var interrupted = false
                    repeat {
                        // Limit each pass so continuously noisy children still reach the deadline check.
                        for (index, fd) in descriptors.enumerated() {
                            for _ in 0..<16 {
                                let count = read(fd, &buffer, buffer.count)
                                guard count > 0 else { break }
                                let remaining = max(0, 4 * 1024 * 1024 - output[index].count)
                                output[index].append(contentsOf: buffer.prefix(min(count, remaining)))
                            }
                        }
                        if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                            interrupted = true
                            break
                        }
                        if !p.isRunning {
                            // One final drain after exit captures bytes written since the first pass.
                            for (index, fd) in descriptors.enumerated() {
                                for _ in 0..<16 {
                                    let count = read(fd, &buffer, buffer.count)
                                    guard count > 0 else { break }
                                    let remaining = max(0, 4 * 1024 * 1024 - output[index].count)
                                    output[index].append(contentsOf: buffer.prefix(min(count, remaining)))
                                }
                            }
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    } while true
                    cont.resume(returning: Result(
                        status: interrupted ? -1 : p.terminationStatus,
                        stdout: String(decoding: output[0], as: UTF8.self),
                        stderr: interrupted ? "Subprocess cancelled or timed out" : String(decoding: output[1], as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Resolve a CLI the way the user's login shell would (GUI apps get a minimal PATH).
    public static func which(_ name: String) async -> String? {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                          Paths.inHome(".local/bin/\(name)").path, Paths.inHome(".bun/bin/\(name)").path]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let r = await run("/bin/zsh", ["-lc", "command -v \(name)"], timeout: 5)
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }
}

// MARK: - JWT

public enum JWT {
    /// Decodes the (unverified) payload of a JWT. Used only for display (email / plan).
    public static func payload(_ token: String) -> JSONObject? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSON.object(data)
    }
}
