import Foundation

/// Helpers for reasoning about when a rolling (non-clock-aligned) quota window is currently
/// ticking vs. idle. Claude's and Codex's 5-hour session windows start on first use and end
/// exactly 5 hours later — there is no active window between that reset and your next message.
public enum WindowSchedule {
    /// True when `windowID` is absent from the snapshot (no session has started this cycle) or its
    /// `resetsAt` has already passed (stale data from a window that already ended). False means the
    /// window is actively ticking down to a future reset.
    public static func isSessionWindowIdle(_ snapshot: ProviderSnapshot?, windowID: String, now: Date = Date()) -> Bool {
        guard let snapshot, snapshot.state == .ok else { return true }
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { return true }
        if let reset = window.resetsAt, reset < now { return true }
        return false
    }
}
