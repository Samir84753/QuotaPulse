import AppKit
import QuotaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(QuotaStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Providers") {
                ForEach(ProviderID.allCases) { id in
                    Toggle(isOn: Binding(
                        get: { store.enabled.contains(id) },
                        set: { on in if on { store.enabled.insert(id) } else { store.enabled.remove(id) } }
                    )) {
                        Label(id.displayName, systemImage: id.symbolName)
                    }
                }
            }
            Section("Display") {
                Picker("Menu bar", selection: $store.menuBarStyle) {
                    ForEach(QuotaStore.MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show remaining (instead of used)", isOn: $store.showRemaining)
                Toggle("Show desktop widget", isOn: $store.desktopWidgetVisible)
            }
            Section("Theme") {
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accent", selection: $store.accent) {
                    ForEach(AppAccent.allCases) { accent in
                        Label(accent.title, systemImage: "circle.fill")
                            .foregroundStyle(accent.color)
                            .tag(accent)
                    }
                }
            }
            Section("Alerts") {
                Toggle("Notify me at 80% / 95% / 100% used", isOn: $store.alertsEnabled)
                Text("A one-time notification per quota window; it resets once that window rolls over.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auto-start") {
                Toggle("Claude: start by", isOn: $store.claudeAutoStartEnabled)
                DatePicker("", selection: $store.claudeAutoStartTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!store.claudeAutoStartEnabled)
                Toggle("Codex: start by", isOn: $store.codexAutoStartEnabled)
                DatePicker("", selection: $store.codexAutoStartTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!store.codexAutoStartEnabled)
                Text("Once a day, at that time, if the 5h window hasn't started yet, QuotaPulse sends one trivial check-in message through your own CLI (in an empty scratch folder, no elevated permissions) so the window — and its reset — starts earlier than it otherwise would.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Stepper("Refresh every \(store.refreshMinutes) min", value: $store.refreshMinutes, in: 1...60)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section {
                Button("Open log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.fileURL])
                }
                Text("QuotaPulse reads the logins your CLIs already have (Claude Code Keychain item, ~/.codex/auth.json, the running Antigravity language server). Nothing leaves your Mac except the providers' own usage endpoints. Claude's \"$ if billed per-token\" figure is a hypothetical pay-per-use estimate computed locally from session token counts — it is not a real charge, and flat-rate Pro/Max subscribers are not billed this amount.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .tint(store.accent.color)
        .preferredColorScheme(store.appearance.colorScheme)
        .task { await store.refresh() }
    }
}
