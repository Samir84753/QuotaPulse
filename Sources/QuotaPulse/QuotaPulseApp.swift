import AppKit
import QuotaCore
import SwiftUI

@main
struct QuotaPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = QuotaStore()

    init() {
        HeadlessMode.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(store)
                .task { store.start() }
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only (also enforced by LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    @Environment(QuotaStore.self) private var store

    var body: some View {
        // The label is created at launch, so kick off the first refresh here too.
        let title = store.menuBarTitle
        HStack(spacing: 3) {
            Image(systemName: store.menuBarSymbol)
            if !title.isEmpty { Text(title).monospacedDigit() }
        }
        .task { store.start() }
    }
}

/// `QuotaPulse --json` prints current quotas and exits (handy for scripts and for the agents verifying builds).
enum HeadlessMode {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--json") else { return }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output = "[]"
        Task.detached {
            let snaps = await ProviderRegistry.fetchAll(ProviderID.allCases)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            output = (try? String(data: enc.encode(snaps), encoding: .utf8)) ?? "[]"
            sem.signal()
        }
        sem.wait()
        print(output)
        exit(0)
    }
}
