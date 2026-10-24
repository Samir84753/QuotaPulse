import Foundation
import QuotaCore
import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct QuotaPulseEntry: TimelineEntry {
    let date: Date
    let snapshots: [ProviderSnapshot]
    let isPlaceholder: Bool

    /// Provider with the highest consumption (tightest quota) among OK providers.
    var worstProviderSnapshot: (ProviderSnapshot, QuotaWindow)? {
        let ok = snapshots.filter { $0.state == .ok }
        return ok.compactMap { s in s.headline.map { (s, $0) } }
            .max(by: { $0.1.usedPercent < $1.1.usedPercent })
    }

    static var placeholderSnapshots: [ProviderSnapshot] {
        [
            ProviderSnapshot(
                provider: .claude,
                state: .ok,
                windows: [QuotaWindow(id: "5h", label: "5h session", usedPercent: 28, resetsAt: Date().addingTimeInterval(7200))]
            ),
            ProviderSnapshot(
                provider: .codex,
                state: .ok,
                windows: [QuotaWindow(id: "weekly", label: "Weekly quota", usedPercent: 60, resetsAt: Date().addingTimeInterval(86400))]
            ),
            ProviderSnapshot(
                provider: .antigravity,
                state: .ok,
                windows: [QuotaWindow(id: "session", label: "Session quota", usedPercent: 15, resetsAt: Date().addingTimeInterval(5400))]
            ),
        ]
    }

    static var placeholder: QuotaPulseEntry {
        QuotaPulseEntry(date: Date(), snapshots: placeholderSnapshots, isPlaceholder: true)
    }
}

// MARK: - Timeline Provider

struct QuotaPulseTimelineProvider: TimelineProvider {
    typealias Entry = QuotaPulseEntry

    func placeholder(in context: Context) -> QuotaPulseEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaPulseEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let snapshots = SnapshotStore.load()
        let entry = QuotaPulseEntry(
            date: Date(),
            snapshots: snapshots,
            isPlaceholder: false
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaPulseEntry>) -> Void) {
        let snapshots = SnapshotStore.load()
        let entry = QuotaPulseEntry(
            date: Date(),
            snapshots: snapshots,
            isPlaceholder: false
        )
        // Refresh every 15 minutes as per widget policy
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(15 * 60)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Colors

enum WidgetQuotaColor {
    static func forUsed(_ used: Double) -> Color {
        switch used {
        case 90...: .red
        case 70..<90: .orange
        case 50..<70: .yellow
        default: .green
        }
    }
}

// MARK: - Size-Specific Views

/// System Small view: worst provider and its quota gauge.
struct SmallWidgetView: View {
    let entry: QuotaPulseEntry

    var body: some View {
        if let (snap, window) = entry.worstProviderSnapshot {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: snap.provider.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(WidgetQuotaColor.forUsed(window.usedPercent))
                    Text(snap.provider.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Gauge(value: window.remainingPercent, in: 0...100) {
                        Image(systemName: snap.provider.symbolName)
                    } currentValueLabel: {
                        Text("\(Int(window.remainingPercent.rounded()))%")
                            .font(.system(.title3, design: .rounded).bold())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(WidgetQuotaColor.forUsed(window.usedPercent))
                    .scaleEffect(1.1)
                    Spacer()
                }

                Spacer(minLength: 0)

                HStack {
                    Text(window.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("remaining")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        } else {
            VStack(alignment: .center, spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("QuotaPulse")
                    .font(.caption.weight(.semibold))
                Text(entry.snapshots.isEmpty ? "No quota data" : "All agents inactive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(4)
        }
    }
}

/// System Medium view: all providers with horizontal bars.
struct MediumWidgetView: View {
    let entry: QuotaPulseEntry

    private var providers: [ProviderSnapshot] {
        var ordered: [ProviderSnapshot] = []
        for id in ProviderID.allCases {
            if let match = entry.snapshots.first(where: { $0.provider == id }) {
                ordered.append(match)
            } else {
                ordered.append(ProviderSnapshot(provider: id, state: .notConfigured))
            }
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agent Quota")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let latest = entry.snapshots.compactMap(\.fetchedAt).max() {
                    Text(latest, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 6) {
                ForEach(providers) { snap in
                    HStack(spacing: 8) {
                        Image(systemName: snap.provider.symbolName)
                            .font(.caption)
                            .frame(width: 14)
                            .foregroundStyle(snap.state == .ok
                                ? snap.headline.map { WidgetQuotaColor.forUsed($0.usedPercent) } ?? .secondary
                                : .secondary)

                        Text(snap.provider.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 82, alignment: .leading)

                        if snap.state == .ok, let w = snap.headline {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.12))
                                        .frame(height: 6)
                                    Capsule()
                                        .fill(WidgetQuotaColor.forUsed(w.usedPercent))
                                        .frame(
                                            width: max(4, min(geo.size.width, geo.size.width * CGFloat(w.remainingPercent / 100.0))),
                                            height: 6
                                        )
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 10)

                            Text("\(Int(w.remainingPercent.rounded()))%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .frame(width: 36, alignment: .trailing)
                        } else {
                            Spacer()
                            Text(stateDescription(snap.state))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(4)
    }

    private func stateDescription(_ state: ProviderState) -> String {
        switch state {
        case .notConfigured: "Not set up"
        case .needsLogin: "Login needed"
        case .error: "Error"
        case .ok: "—"
        }
    }
}

// MARK: - Entry View Router

struct QuotaPulseWidgetEntryView: View {
    var entry: QuotaPulseEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Definition

@main
struct QuotaPulseWidget: Widget {
    let kind: String = "QuotaPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuotaPulseTimelineProvider()) { entry in
            QuotaPulseWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("QuotaPulse")
        .description("Shows remaining AI agent quota at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
