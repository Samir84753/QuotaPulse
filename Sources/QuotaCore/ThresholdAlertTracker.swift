import Foundation

/// Tracks which (provider, window, threshold) combinations have already fired, so a refresh loop
/// can alert once per crossing rather than on every refresh while a window sits above a threshold.
/// Pure value logic — QuotaCore stays notification/UI-framework free; callers decide how to alert.
public struct ThresholdAlertTracker: Sendable {
    public struct Crossing: Sendable, Equatable {
        public var provider: ProviderID
        public var windowLabel: String
        public var threshold: Int
        public var usedPercent: Double
    }

    private struct State: Equatable { var threshold: Int; var resetsAt: Date? }
    private var notified: [String: State] = [:]

    public init() {}

    /// Compares each window's `usedPercent` against `thresholds` and returns every threshold newly
    /// crossed since the last call, highest-reached-threshold semantics (crossing straight from 60%
    /// to 97% reports only 95%, not 80% then 95%). A window whose `resetsAt` changes — i.e. it
    /// rolled over — starts fresh, so the same thresholds can fire again next cycle.
    public mutating func crossings(for snapshots: [ProviderSnapshot], thresholds: [Int]) -> [Crossing] {
        var events: [Crossing] = []
        let sortedThresholds = thresholds.sorted()
        for snapshot in snapshots where snapshot.state == .ok {
            for window in snapshot.windows {
                let key = "\(snapshot.provider.rawValue)-\(window.id)"
                if let existing = notified[key], existing.resetsAt != window.resetsAt {
                    notified[key] = nil
                }
                let already = notified[key]?.threshold ?? 0
                guard let crossed = sortedThresholds.last(where: { $0 <= Int(window.usedPercent) && $0 > already }) else { continue }
                notified[key] = State(threshold: crossed, resetsAt: window.resetsAt)
                events.append(Crossing(provider: snapshot.provider, windowLabel: window.label,
                                       threshold: crossed, usedPercent: window.usedPercent))
            }
        }
        return events
    }
}
