import AppKit
import QuotaCore
import SwiftUI

/// A borderless panel pinned to the desktop layer: a "desktop widget" that works without code signing.
/// (A real WidgetKit widget lives in the optional Xcode target – see tasks/AGY-02-widgetkit.md.)
@MainActor
final class DesktopWidgetController {
    static let shared = DesktopWidgetController()
    private var panel: NSPanel?

    func setVisible(_ visible: Bool, store: QuotaStore) {
        if visible {
            if panel == nil { panel = makePanel(store: store) }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel(store: QuotaStore) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setFrameAutosaveName("QuotaPulseDesktopWidget")
        let host = NSHostingView(rootView: DesktopWidgetView().environment(store))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        if !panel.setFrameUsingName("QuotaPulseDesktopWidget"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 280, y: f.maxY - 240))
        }
        return panel
    }
}

struct DesktopWidgetView: View {
    @Environment(QuotaStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent quota").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let last = store.lastRefresh { Text(last, style: .time).font(.caption2).foregroundStyle(.tertiary) }
            }
            ForEach(store.visibleSnapshots) { snap in
                HStack(spacing: 8) {
                    Image(systemName: snap.provider.symbolName).frame(width: 14)
                    Text(snap.provider.displayName).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    if let w = snap.headline, snap.state == .ok {
                        Gauge(value: w.remainingPercent, in: 0...100) { EmptyView() }
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(QuotaColor.forUsed(w.usedPercent))
                            .scaleEffect(0.55)
                            .frame(width: 26, height: 26)
                        Text(store.percentText(w)).font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 38, alignment: .trailing)
                    } else {
                        Text("—").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Refresh") { Task { await store.refresh() } }
            Button("Hide widget") { store.desktopWidgetVisible = false }
        }
    }
}
