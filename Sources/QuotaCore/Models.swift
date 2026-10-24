import Foundation

/// Every agent harness QuotaPulse knows how to read.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// Short label used in the menu bar title (e.g. "C 42%").
    public var shortLabel: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .antigravity: "A"
        }
    }

    /// SF Symbol used in cards and widgets.
    public var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "arrow.up.circle"
        }
    }
}

/// One rate-limit window (e.g. Claude's 5-hour session, Codex weekly, an Antigravity model bucket).
public struct QuotaWindow: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    /// 0...100, how much of the window has been consumed.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Length of the window in seconds when known (18000 = 5h, 604800 = 7d).
    public var windowSeconds: Int?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil, windowSeconds: Int? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent.isFinite ? min(max(usedPercent, 0), 100) : 0
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    public var remainingPercent: Double { 100 - usedPercent }
}

/// An approximate dollar cost derived from local session token counts (never from a billing API).
/// Anthropic/OpenAI don't expose real-time $ spend for flat-rate subscription plans, so this is a
/// best-effort estimate using public per-model token pricing, which can drift out of date.
public struct CostEstimate: Codable, Sendable, Hashable {
    public var totalUSD: Decimal
    public var periodStart: Date
    public var inputTokens: Int
    public var outputTokens: Int

    public init(totalUSD: Decimal, periodStart: Date, inputTokens: Int, outputTokens: Int) {
        self.totalUSD = totalUSD
        self.periodStart = periodStart
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum ProviderState: String, Codable, Sendable {
    case ok
    case notConfigured   // CLI not installed / never logged in
    case needsLogin      // credentials present but expired/invalid
    case error
}

/// Result of one fetch for one provider.
public struct ProviderSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var provider: ProviderID
    public var state: ProviderState
    public var windows: [QuotaWindow]
    public var plan: String?
    public var account: String?
    public var message: String?
    public var source: String?
    public var fetchedAt: Date
    public var costEstimate: CostEstimate?

    public var id: String { provider.rawValue }

    public init(
        provider: ProviderID,
        state: ProviderState,
        windows: [QuotaWindow] = [],
        plan: String? = nil,
        account: String? = nil,
        message: String? = nil,
        source: String? = nil,
        fetchedAt: Date = Date(),
        costEstimate: CostEstimate? = nil
    ) {
        self.provider = provider
        self.state = state
        self.windows = windows
        self.plan = plan
        self.account = account
        self.message = message
        self.source = source
        self.fetchedAt = fetchedAt
        self.costEstimate = costEstimate
    }

    /// The most constrained window: what the menu bar shows.
    public var headline: QuotaWindow? {
        windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    public static func failure(_ provider: ProviderID, _ error: Error) -> ProviderSnapshot {
        if let qe = error as? QuotaError {
            return ProviderSnapshot(provider: provider, state: qe.state, message: qe.message)
        }
        return ProviderSnapshot(provider: provider, state: .error, message: error.localizedDescription)
    }
}

public enum QuotaError: Error, LocalizedError, Sendable {
    case notConfigured(String)
    case needsLogin(String)
    case http(Int, String)
    case parse(String)
    case other(String)

    public var state: ProviderState {
        switch self {
        case .notConfigured: .notConfigured
        case .needsLogin: .needsLogin
        default: .error
        }
    }

    public var message: String {
        switch self {
        case let .notConfigured(m), let .needsLogin(m), let .parse(m), let .other(m): m
        case let .http(code, _): "Provider request failed (HTTP \(code)). Try refreshing again."
        }
    }

    public var errorDescription: String? { message }
}

/// Contract every provider implements. Must never throw for "not installed": return a snapshot instead.
public protocol QuotaProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> ProviderSnapshot
}
