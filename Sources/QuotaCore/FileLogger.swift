import Foundation

/// A small, rotating, append-only log file for debugging refresh cycles and provider failures.
/// Callers are responsible for never passing tokens/secrets/HTTP bodies — this only writes the
/// string it is given, verbatim, so every call site must already be redacted (see AGENTS.md rule 2).
public final class FileLogger: Sendable {
    public static let shared = FileLogger()

    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "quotapulse.filelogger")

    public init(url: URL? = nil, maxBytes: Int = 1_000_000) {
        self.url = url ?? FileLogger.defaultURL
        self.maxBytes = maxBytes
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? Paths.inHome("Library")
        return base.appendingPathComponent("Logs/QuotaPulse/quotapulse.log")
    }

    public var fileURL: URL { url }

    public func log(_ message: String) {
        queue.async { [url, maxBytes] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            _ = try? handle.seekToEnd()
            handle.write(data)
            let size = (try? handle.offset()) ?? 0
            try? handle.close()
            if size > UInt64(maxBytes) {
                Self.trim(url, to: maxBytes / 2)
            }
        }
    }

    private static func trim(_ url: URL, to keepBytes: Int) {
        guard let data = try? Data(contentsOf: url), data.count > keepBytes else { return }
        try? data.suffix(keepBytes).write(to: url, options: .atomic)
    }
}
