import Foundation
import Observation
import QuotaCore
import SwiftUI

@MainActor
@Observable
final class QuotaStore {
    var snapshots: [ProviderSnapshot] = SnapshotStore.load()
    var isRefreshing = false
    var lastRefresh: Date?

    // Settings (persisted in UserDefaults)
    var enabled: Set<ProviderID> { didSet { persist() } }
    var refreshMinutes: Int { didSet { persist(); restartTimer() } }
    var showRemaining: Bool { didSet { persist() } }
    var menuBarStyle: MenuBarStyle { didSet { persist() } }
    var desktopWidgetVisible: Bool { didSet { persist(); DesktopWidgetController.shared.setVisible(desktopWidgetVisible, store: self) } }
    var alertsEnabled: Bool { didSet { persist(); if alertsEnabled { Task { await NotificationAlerter.shared.requestPermissionIfNeeded() } } } }
    var appearance: AppAppearance { didSet { persist() } }
    var accent: AppAccent { didSet { persist() } }

    /// Auto-start: once a day, at the chosen time, if that provider's 5h window hasn't started yet,
    /// send one trivial check-in so the window (and its reset) starts earlier than it otherwise would.
    var claudeAutoStartEnabled: Bool { didSet { persist() } }
    var codexAutoStartEnabled: Bool { didSet { persist() } }
    private var claudeAutoStartMinutes: Int { didSet { persist() } }
    private var codexAutoStartMinutes: Int { didSet { persist() } }
    var claudeAutoStartTime: Date {
        get { Self.date(fromMinutesSinceMidnight: claudeAutoStartMinutes) }
        set { claudeAutoStartMinutes = Self.minutesSinceMidnight(newValue) }
    }
    var codexAutoStartTime: Date {
        get { Self.date(fromMinutesSinceMidnight: codexAutoStartMinutes) }
        set { codexAutoStartMinutes = Self.minutesSinceMidnight(newValue) }
    }

    private static func minutesSinceMidnight(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 7) * 60 + (c.minute ?? 0)
    }
    private static func date(fromMinutesSinceMidnight minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    /// Used-percent thresholds that trigger a one-time notification per quota window.
    static let alertThresholds = [80, 95, 100]
    @ObservationIgnored private var alertTracker = ThresholdAlertTracker()
    @ObservationIgnored private var autoSendTimerTask: Task<Void, Never>?
    /// provider rawValue -> "yyyy-MM-dd" of the last day auto-start already ran (sent or skipped) for it.
    @ObservationIgnored private var lastAutoSendDay: [String: String] = [:]
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case compact, iconOnly, worst
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: "Every provider (C 72% · X 40%)"
            case .iconOnly: "Icon only"
            case .worst: "Most constrained only"
            }
        }
    }

    private var timerTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        let saved = defaults.stringArray(forKey: "enabledProviders")?.compactMap(ProviderID.init(rawValue:))
        enabled = Set(saved ?? ProviderID.allCases)
        refreshMinutes = min(60, max(1, defaults.object(forKey: "refreshMinutes") as? Int ?? 5))
        showRemaining = defaults.object(forKey: "showRemaining") as? Bool ?? true
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .compact
        desktopWidgetVisible = defaults.bool(forKey: "desktopWidgetVisible")
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accent = AppAccent(rawValue: defaults.string(forKey: "accent") ?? "") ?? .blue
        claudeAutoStartEnabled = defaults.bool(forKey: "claudeAutoStartEnabled")
        codexAutoStartEnabled = defaults.bool(forKey: "codexAutoStartEnabled")
        claudeAutoStartMinutes = defaults.object(forKey: "claudeAutoStartMinutes") as? Int ?? 7 * 60
        codexAutoStartMinutes = defaults.object(forKey: "codexAutoStartMinutes") as? Int ?? 7 * 60
        lastAutoSendDay = defaults.dictionary(forKey: "lastAutoSendDay") as? [String: String] ?? [:]
    }

    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        restartTimer()
        restartAutoSendTimer()
        if desktopWidgetVisible { DesktopWidgetController.shared.setVisible(true, store: self) }
        if alertsEnabled { Task { await NotificationAlerter.shared.requestPermissionIfNeeded() } }
    }

    private func persist() {
        defaults.set(enabled.map(\.rawValue), forKey: "enabledProviders")
        defaults.set(refreshMinutes, forKey: "refreshMinutes")
        defaults.set(showRemaining, forKey: "showRemaining")
        defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
        defaults.set(desktopWidgetVisible, forKey: "desktopWidgetVisible")
        defaults.set(alertsEnabled, forKey: "alertsEnabled")
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(accent.rawValue, forKey: "accent")
        defaults.set(claudeAutoStartEnabled, forKey: "claudeAutoStartEnabled")
        defaults.set(codexAutoStartEnabled, forKey: "codexAutoStartEnabled")
        defaults.set(claudeAutoStartMinutes, forKey: "claudeAutoStartMinutes")
        defaults.set(codexAutoStartMinutes, forKey: "codexAutoStartMinutes")
    }

    private func restartTimer() {
        timerTask?.cancel()
        let interval = UInt64(refreshMinutes) * 60 * 1_000_000_000
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func restartAutoSendTimer() {
        autoSendTimerTask?.cancel()
        autoSendTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAutoSend()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func checkAutoSend() async {
        await checkAutoSend(for: .claude, enabled: claudeAutoStartEnabled, scheduledTime: claudeAutoStartTime, windowID: "claude-five_hour")
        await checkAutoSend(for: .codex, enabled: codexAutoStartEnabled, scheduledTime: codexAutoStartTime, windowID: "codex-primary_window")
    }

    private func checkAutoSend(for provider: ProviderID, enabled: Bool, scheduledTime: Date, windowID: String) async {
        guard enabled else { return }
        let now = Date()
        let today = Self.dayFormatter.string(from: now)
        guard lastAutoSendDay[provider.rawValue] != today else { return }

        let comps = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        guard let scheduledToday = Calendar.current.date(bySettingHour: comps.hour ?? 7, minute: comps.minute ?? 0, second: 0, of: now),
              now >= scheduledToday else { return }

        lastAutoSendDay[provider.rawValue] = today
        defaults.set(lastAutoSendDay, forKey: "lastAutoSendDay")

        let snapshot = snapshots.first(where: { $0.provider == provider })
        guard WindowSchedule.isSessionWindowIdle(snapshot, windowID: windowID, now: now) else {
            FileLogger.shared.log("auto-send \(provider.rawValue): window already active, skipped")
            return
        }
        FileLogger.shared.log("auto-send \(provider.rawValue): window idle, sending check-in")
        await AutoSender.send(provider: provider)
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let ids = ProviderID.allCases.filter { enabled.contains($0) }
        FileLogger.shared.log("refresh start providers=\(ids.map(\.rawValue))")
        let fresh = await ProviderRegistry.fetchAll(ids)
        // Keep last good windows when a provider transiently errors.
        snapshots = fresh.map { new in
            if new.state == .error, let old = snapshots.first(where: { $0.provider == new.provider }), old.state == .ok {
                var kept = old
                kept.message = "Stale: \(new.message ?? "refresh failed")"
                return kept
            }
            return new
        }
        lastRefresh = Date()
        FileLogger.shared.log("refresh done " + snapshots.map { "\($0.provider.rawValue)=\($0.state.rawValue)" }.joined(separator: " "))
        if alertsEnabled {
            let crossings = alertTracker.crossings(for: snapshots, thresholds: Self.alertThresholds)
            if !crossings.isEmpty { NotificationAlerter.shared.send(crossings) }
        }
        let savedSnapshots = snapshots
        await Task.detached(priority: .utility) { SnapshotStore.save(savedSnapshots) }.value
        WidgetBridge.reloadTimelines()
    }

    var visibleSnapshots: [ProviderSnapshot] {
        snapshots.filter { enabled.contains($0.provider) }
    }

    // MARK: Menu bar text

    func percentText(_ w: QuotaWindow) -> String {
        "\(Int((showRemaining ? w.remainingPercent : w.usedPercent).rounded()))%"
    }

    var menuBarTitle: String {
        let ok = visibleSnapshots.filter { $0.state == .ok }
        switch menuBarStyle {
        case .iconOnly: return ""
        case .worst:
            guard let worst = ok.compactMap({ s in s.headline.map { (s, $0) } }).max(by: { $0.1.usedPercent < $1.1.usedPercent })
            else { return ok.isEmpty ? "—" : "" }
            return "\(worst.0.provider.shortLabel) \(percentText(worst.1))"
        case .compact:
            let parts = ok.compactMap { s in s.headline.map { "\(s.provider.shortLabel) \(percentText($0))" } }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }
    }

    /// Icon reflects the tightest window across providers.
    var menuBarSymbol: String {
        let worst = visibleSnapshots.compactMap(\.headline).map(\.usedPercent).max() ?? 0
        switch worst {
        case 90...: return "gauge.with.dots.needle.100percent"
        case 60..<90: return "gauge.with.dots.needle.67percent"
        case 30..<60: return "gauge.with.dots.needle.50percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}

enum QuotaColor {
    static func forUsed(_ used: Double) -> Color {
        switch used {
        case 90...: .red
        case 70..<90: .orange
        case 50..<70: .yellow
        default: .green
        }
    }
}

enum WidgetBridge {
    /// WidgetKit reload hook. The WidgetKit extension (Xcode target, see tasks/AGY-02) reads SnapshotStore.
    static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetReloader.reload()
        #endif
    }
}
