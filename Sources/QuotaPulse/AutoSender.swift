import Foundation
import QuotaCore

/// Sends one trivial, tool-free prompt to the Claude or Codex CLI to deliberately start their
/// rolling 5-hour session window at a time the user chose, rather than whenever they happen to
/// first use the agent that day — starting earlier means that window's reset lands earlier too.
///
/// This is QuotaPulse's one feature that *acts* rather than just reads: it runs the user's own CLI,
/// exactly as if they'd typed a message themselves, in a dedicated empty scratch directory (never a
/// real project) and without any elevated/auto-approve flags, so the model has nothing to read or
/// act on beyond replying to a one-line check-in. Every attempt is logged to `FileLogger`.
enum AutoSender {
    private static let prompt = "Automated daily quota check-in from QuotaPulse. Reply with just: ok"

    private static var scratchDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaPulseAutoSend", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func send(provider: ProviderID) async {
        switch provider {
        case .claude:
            guard let bin = await Shell.which("claude") else {
                FileLogger.shared.log("auto-send claude: CLI not found on PATH, skipped")
                return
            }
            let r = await Shell.run(bin, ["-p", prompt, "--output-format", "text"], timeout: 60, workingDirectory: scratchDir)
            FileLogger.shared.log(r.status == 0 ? "auto-send claude: ok" : "auto-send claude: failed status=\(r.status)")
        case .codex:
            guard let bin = await Shell.which("codex") else {
                FileLogger.shared.log("auto-send codex: CLI not found on PATH, skipped")
                return
            }
            let args = ["exec", "-s", "read-only", "-C", scratchDir.path, "--skip-git-repo-check", prompt]
            let r = await Shell.run(bin, args, timeout: 60, workingDirectory: scratchDir)
            FileLogger.shared.log(r.status == 0 ? "auto-send codex: ok" : "auto-send codex: failed status=\(r.status)")
        case .antigravity:
            return
        }
    }
}
