import Foundation

public enum ProviderRegistry {
    public static func provider(for id: ProviderID) -> any QuotaProvider {
        switch id {
        case .claude: ClaudeProvider()
        case .codex: CodexProvider()
        case .antigravity: AntigravityProvider()
        }
    }

    /// Fetches all requested providers concurrently.
    public static func fetchAll(_ ids: [ProviderID]) async -> [ProviderSnapshot] {
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for id in ids { group.addTask { await provider(for: id).fetch() } }
            var out: [ProviderSnapshot] = []
            for await s in group { out.append(s) }
            return out.sorted { a, b in
                (ProviderID.allCases.firstIndex(of: a.provider) ?? 0) < (ProviderID.allCases.firstIndex(of: b.provider) ?? 0)
            }
        }
    }
}

/// JSON snapshot on disk: `~/Library/Application Support/QuotaPulse/snapshots.json`.
/// Shared with the WidgetKit extension (via App Group when signed) and the `quotapulse --json` CLI mode.
public enum SnapshotStore {
    public static var appGroupID = "group.com.quotapulse.shared"

    public static var url: URL {
        #if os(macOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("snapshots.json")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? Paths.inHome("Library/Application Support")
        return base.appendingPathComponent("QuotaPulse/snapshots.json")
    }

    public static func save(_ snapshots: [ProviderSnapshot]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshots) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func load() -> [ProviderSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ProviderSnapshot].self, from: data)) ?? []
    }
}
