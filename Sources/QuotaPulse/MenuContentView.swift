import AppKit
import QuotaCore
import SwiftUI

/// Measures the natural height of the card stack so the ScrollView below can be given a
/// concrete `.frame(height:)`. A plain `ScrollView` has no intrinsic content height, so inside
/// `MenuBarExtra`'s auto-sizing `.window` popover it collapses to ~0pt even with real content —
/// giving it a measured, capped height is what makes the popover size itself correctly.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuContentView: View {
    @Environment(QuotaStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var cardStackHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if store.visibleSnapshots.isEmpty {
                ContentUnavailableView("Loading quotas…", systemImage: "hourglass")
                    .frame(height: 120)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.visibleSnapshots) { snap in
                            ProviderCard(snapshot: snap)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .onPreferenceChange(ContentHeightKey.self) { cardStackHeight = $0 }
                .frame(height: min(max(cardStackHeight, 40), 520))
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .tint(store.accent.color)
        .preferredColorScheme(store.appearance.colorScheme)
    }

    private var header: some View {
        HStack {
            Label("QuotaPulse", systemImage: "gauge.with.dots.needle.50percent")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .keyboardShortcut("r")
        }
    }

    private var footer: some View {
        HStack {
            if let last = store.lastRefresh {
                Text("Updated \(last, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            @Bindable var store = store
            Toggle(isOn: $store.desktopWidgetVisible) { Image(systemName: "rectangle.on.rectangle") }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help("Show desktop widget")
            Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit QuotaPulse")
                .keyboardShortcut("q")
        }
    }
}

struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    @State private var showAllWindows = false

    private var rankedWindows: [QuotaWindow] {
        snapshot.windows.sorted {
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent > $1.usedPercent }
            return $0.label < $1.label
        }
    }
    @Environment(QuotaStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.provider.symbolName).frame(width: 16)
                Text(snapshot.provider.displayName).font(.subheadline.weight(.semibold))
                if let plan = snapshot.plan {
                    Text(plan).font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                stateBadge
            }
            if snapshot.state == .ok {
                ForEach(Array(rankedWindows.prefix(4))) { w in WindowRow(window: w) }
                if rankedWindows.count > 4 {
                    DisclosureGroup("Show all (\(rankedWindows.count) windows)", isExpanded: $showAllWindows) {
                        ForEach(Array(rankedWindows.dropFirst(4))) { w in WindowRow(window: w) }
                    }
                    .font(.caption)
                }
            }
            if let cost = snapshot.costEstimate {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle").font(.caption2)
                    Text("~\(cost.totalUSD.formatted(.currency(code: "USD"))) if billed per-token · last 7 days")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .help("Hypothetical pay-per-token cost estimated from local session logs — not a real charge against your plan, and not an authoritative figure.")
            }
            if let msg = snapshot.message {
                Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let account = snapshot.account {
                Text(account).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var stateBadge: some View {
        switch snapshot.state {
        case .ok: EmptyView()
        case .notConfigured: Image(systemName: "minus.circle").foregroundStyle(.secondary).help("Not set up")
        case .needsLogin: Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange).help("Login needed")
        case .error: Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).help("Error")
        }
    }
}

struct WindowRow: View {
    let window: QuotaWindow
    @Environment(QuotaStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.caption).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer()
                Text(store.showRemaining ? "\(store.percentText(window)) left" : "\(store.percentText(window)) used")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            ProgressView(value: store.showRemaining ? window.remainingPercent : window.usedPercent, total: 100)
                .tint(QuotaColor.forUsed(window.usedPercent))
            if let reset = window.resetsAt, reset > Date() {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
