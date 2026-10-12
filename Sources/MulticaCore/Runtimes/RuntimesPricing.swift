import Foundation

/// USD per million tokens.
public struct RuntimesModelPrice: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// Any per-model usage row that can be priced.
public protocol RuntimesPriceable {
    var model: String { get }
    var runtimesProvider: String? { get }
    var inputTokens: Int { get }
    var outputTokens: Int { get }
    var cacheReadTokens: Int { get }
    var cacheWriteTokens: Int { get }
    var costUsdTicks: Double? { get }
    var uncostedInputTokens: Int? { get }
    var uncostedOutputTokens: Int? { get }
    var uncostedCacheReadTokens: Int? { get }
    var uncostedCacheWriteTokens: Int? { get }
}

extension RuntimesPriceable {
    public var runtimesTotalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

extension RuntimeUsage: RuntimesPriceable {
    public var runtimesProvider: String? { provider.isEmpty ? nil : provider }
}

extension RuntimeUsageByAgent: RuntimesPriceable {
    public var runtimesProvider: String? { provider.isEmpty ? nil : provider }
}

extension RuntimeUsageByHour: RuntimesPriceable {
    public var runtimesProvider: String? { nil }
}

public struct RuntimesCostBreakdown: Sendable, Hashable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0

    public var total: Double { input + output + cacheRead + cacheWrite }
}

/// Cost estimation for usage rows: the maintained rate table plus the
/// user's custom rates (upstream `utils.ts` `estimateCost` & co.).
public struct RuntimesPricer: Sendable {
    public var custom: [String: RuntimesModelPrice]

    public init(custom: [String: RuntimesModelPrice] = [:]) {
        self.custom = custom
    }

    /// Providers report cost in ticks of 1e-10 USD.
    static let ticksPerUSD = 10_000_000_000.0

    static let table: [String: RuntimesModelPrice] = {
        func p(_ i: Double, _ o: Double, _ r: Double, _ w: Double) -> RuntimesModelPrice { RuntimesModelPrice(input: i, output: o, cacheRead: r, cacheWrite: w) }
        return [
            "claude-sonnet-5": p(2, 10, 0.20, 2.50),
            "claude-fable-5-1": p(10, 50, 0.25, 12.50),
            "claude-fable-5": p(10, 50, 1.00, 12.50),
            "claude-opus-5-5": p(4, 20, 0.20, 5.00),
            "claude-opus-5": p(5, 25, 0.50, 6.25),
            "claude-haiku-4-5": p(1, 5, 0.10, 1.25),
            "claude-sonnet-4-5": p(3, 15, 0.30, 3.75),
            "claude-sonnet-4-6": p(3, 15, 0.30, 3.75),
            "claude-opus-4-5": p(5, 25, 0.50, 6.25),
            "claude-opus-4-6": p(5, 25, 0.50, 6.25),
            "claude-opus-4-7": p(5, 25, 0.50, 6.25),
            "claude-opus-4-8": p(5, 25, 0.50, 6.25),
            "claude-opus-4-1": p(15, 75, 1.50, 18.75),
            "claude-opus-4": p(15, 75, 1.50, 18.75),
            "claude-sonnet-4": p(3, 15, 0.30, 3.75),
            "claude-haiku-3-5": p(0.80, 4, 0.08, 1.00),
            "gpt-6-astra": p(10, 50, 1.00, 12.50),
            "gpt-6.1-sol": p(2, 10, 0.10, 2.50),
            "gpt-6-sol": p(2, 10, 0.20, 2.50),
            "gpt-6-luna": p(0.10, 0.50, 0.01, 0.125),
            "gpt-5.6-sol": p(5, 30, 0.50, 6.25),
            "gpt-5.6-terra": p(2.50, 15, 0.25, 3.125),
            "gpt-5.6-luna": p(1, 6, 0.10, 1.25),
            "gpt-5.5": p(5, 30, 0.50, 5),
            "gpt-5.4-mini": p(0.75, 4.50, 0.075, 0.75),
            "gpt-5.4": p(2.50, 15, 0.25, 2.50),
            "gpt-5.3-codex": p(1.75, 14, 0.175, 1.75),
            "gpt-5-codex": p(1.25, 10, 0.125, 1.25),
            "gpt-5-mini": p(0.25, 2, 0.025, 0.25),
            "gpt-5-nano": p(0.05, 0.40, 0.005, 0.05),
            "gpt-5": p(1.25, 10, 0.125, 1.25),
            "o3-mini": p(1.10, 4.40, 0.55, 1.10),
            "o3": p(2, 8, 0.50, 2),
            "o4-mini": p(1.10, 4.40, 0.275, 1.10),
            "gpt-4o-mini": p(0.15, 0.60, 0.075, 0.15),
            "gpt-4o": p(2.50, 10, 1.25, 2.50),
            "deepseek-v4-flash": p(0.14, 0.28, 0.0028, 0.14),
            "deepseek-v4-pro": p(1.74, 3.48, 0.0145, 1.74),
            "deepseek-chat": p(0.14, 0.28, 0.0028, 0.14),
            "deepseek-reasoner": p(0.14, 0.28, 0.0028, 0.14),
            "kimi-k2.6": p(0.95, 4.00, 0.16, 0.95),
            "kimi-k3": p(3.0, 15.0, 0.30, 3.0),
            "kimi/k3": p(3.0, 15.0, 0.30, 3.0),
            "glm-5.1": p(1.4, 4.4, 0.26, 1.4),
            "glm-5": p(1.0, 3.2, 0.2, 1.0),
            "glm-5-turbo": p(1.2, 4.0, 0.24, 1.2),
            "glm-4.7": p(0.6, 2.2, 0.11, 0.6),
            "glm-4.7-flashx": p(0.07, 0.4, 0.01, 0.07),
            "glm-4.7-flash": p(0, 0, 0, 0),
            "glm-4.6": p(0.6, 2.2, 0.11, 0.6),
            "glm-4.5": p(0.6, 2.2, 0.11, 0.6),
            "glm-4.5-x": p(2.2, 8.9, 0.45, 2.2),
            "glm-4.5-air": p(0.2, 1.1, 0.03, 0.2),
            "glm-4.5-airx": p(1.1, 4.5, 0.22, 1.1),
            "glm-4.5-flash": p(0, 0, 0, 0),
            "qwen3.7-plus": p(0.40, 1.60, 0.04, 0.50),
            "qwen3.6-flash": p(0.25, 1.50, 0.025, 0.3125),
            "qwen3.8-max": p(2.00, 6.00, 0.17, 2.5),
            "qwen3.8-max-preview": p(0, 0, 0, 0),
            "grok-4.6": p(2, 6, 0.50, 2),
            "grok-4.5": p(2, 6, 0.30, 2),
            "grok-4.3": p(1.25, 2.50, 0.20, 1.25),
            "grok-build-0.1": p(1, 2, 0.20, 1),
            "grok-4.20-multi-agent-0309": p(1.25, 2.50, 0.20, 1.25),
            "grok-4.20-0309-reasoning": p(1.25, 2.50, 0.20, 1.25),
            "grok-4.20-0309-non-reasoning": p(1.25, 2.50, 0.20, 1.25),
            "cursor/auto": p(1.25, 6, 0.25, 0),
            "cursor/composer-2.5-fast": p(3, 15, 0.5, 0),
            "cursor/composer-2.5": p(0.5, 2.5, 0.2, 0),
            "cursor/composer-2-fast": p(1.5, 7.5, 0.35, 0),
            "cursor/composer-2": p(0.5, 2.5, 0.2, 0),
            "cursor/composer-1.5": p(3.5, 17.5, 0.35, 0),
            "cursor/composer-1": p(1.25, 10, 0.125, 0),
            "cursor": p(3, 15, 0.5, 0),
        ]
    }()

    private static let candidateCache = Locked<[String: [String]]>([:])

    /// Lookup candidates for a raw model id, in priority order: the raw id,
    /// then with routing prefixes stripped, Anthropic dots dashed, context
    /// tags and dated snapshots removed.
    static func canonicalCandidates(_ model: String) -> [String] {
        if let hit = candidateCache.withLock({ $0[model] }) { return hit }
        var out: [String] = []
        func push(_ s: String) { if !s.isEmpty && !out.contains(s) { out.append(s) } }
        func stripDate(_ s: String) -> String { s.replacing(/-(20\d{2}-\d{2}-\d{2}|20\d{6}|latest)$/, with: "") }
        func stripProvider(_ s: String) -> String {
            var work = Substring(s)
            while true {
                let sep = work.firstIndex(where: { $0 == "/" || $0 == ":" })
                guard let sep, sep > work.startIndex, work[..<sep].wholeMatch(of: /[a-zA-Z][a-zA-Z0-9_-]*/) != nil else { break }
                work = work[work.index(after: sep)...]
            }
            return String(work)
        }
        func canonAnthropic(_ s: String) -> String { s.hasPrefix("claude-") ? s.replacingOccurrences(of: ".", with: "-") : s }
        func stripContextTag(_ s: String) -> String { s.replacing(/\[[^\]]+\]$/, with: "") }
        let noProvider = stripProvider(model)
        let dashed = canonAnthropic(noProvider)
        let noTag = stripContextTag(dashed)
        for s in [model, noProvider, dashed, noTag, stripDate(model), stripDate(noProvider), stripDate(dashed), stripDate(noTag)] { push(s) }
        candidateCache.withLock { $0[model] = out }
        return out
    }

    static func normalizeProvider(_ provider: String?) -> String {
        provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func qualify(_ provider: String, _ key: String) -> String {
        key.hasPrefix("\(provider)/") ? key : "\(provider)/\(key)"
    }

    static func candidates(_ model: String, provider: String?) -> [String] {
        let base = canonicalCandidates(model)
        let p = normalizeProvider(provider)
        guard !p.isEmpty else { return base }
        return base.map { qualify(p, $0) } + base
    }

    /// Storage/diagnostic key: provider-qualified when a provider is known.
    public static func pricingKey(_ model: String, provider: String?) -> String {
        let p = normalizeProvider(provider)
        return p.isEmpty ? model : qualify(p, model)
    }

    public func resolve(_ model: String, provider: String?) -> RuntimesModelPrice? {
        guard !model.isEmpty else { return nil }
        let keys = Self.candidates(model, provider: provider)
        for k in keys { if let hit = Self.table[k] { return hit } }
        for k in keys { if let hit = custom[k] { return hit } }
        return nil
    }

    public func isPriced(_ model: String, provider: String? = nil) -> Bool {
        resolve(model, provider: provider) != nil
    }

    /// Grouping key for a row's model: self-resolving ids stay bare, generic
    /// ids are provider-qualified so two providers never merge.
    public func modelGroupingKey(_ model: String, provider: String?) -> String {
        if model.isEmpty { return Self.normalizeProvider(provider).isEmpty ? "unknown" : Self.normalizeProvider(provider) }
        return isPriced(model) ? model : Self.pricingKey(model, provider: provider)
    }

    static func uncosted(_ u: some RuntimesPriceable) -> RuntimesCostBreakdown {
        guard let uncostedInput = u.uncostedInputTokens else {
            if (u.costUsdTicks ?? 0) > 0 { return RuntimesCostBreakdown() }
            return RuntimesCostBreakdown(input: Double(u.inputTokens), output: Double(u.outputTokens),
                                         cacheRead: Double(u.cacheReadTokens), cacheWrite: Double(u.cacheWriteTokens))
        }
        return RuntimesCostBreakdown(input: Double(uncostedInput), output: Double(u.uncostedOutputTokens ?? 0),
                                     cacheRead: Double(u.uncostedCacheReadTokens ?? 0), cacheWrite: Double(u.uncostedCacheWriteTokens ?? 0))
    }

    /// What the provider charged, plus a rate-table estimate for the rest.
    public func estimateCost(_ u: some RuntimesPriceable) -> Double {
        let authoritative = (u.costUsdTicks ?? 0) / Self.ticksPerUSD
        guard let price = resolve(u.model, provider: u.runtimesProvider) else { return authoritative }
        let t = Self.uncosted(u)
        return authoritative + (t.input * price.input + t.output * price.output + t.cacheRead * price.cacheRead + t.cacheWrite * price.cacheWrite) / 1_000_000
    }

    /// Per-token-type split of `estimateCost`; the authoritative charge is
    /// distributed in the proportions the rate table would have used.
    public func estimateCostBreakdown(_ u: some RuntimesPriceable) -> RuntimesCostBreakdown {
        let authoritative = (u.costUsdTicks ?? 0) / Self.ticksPerUSD
        guard let price = resolve(u.model, provider: u.runtimesProvider) else {
            return RuntimesCostBreakdown(input: authoritative)
        }
        let t = Self.uncosted(u)
        let estimated = RuntimesCostBreakdown(input: t.input * price.input / 1_000_000, output: t.output * price.output / 1_000_000,
                                              cacheRead: t.cacheRead * price.cacheRead / 1_000_000, cacheWrite: t.cacheWrite * price.cacheWrite / 1_000_000)
        guard authoritative > 0 else { return estimated }
        let shape = RuntimesCostBreakdown(
            input: (Double(u.inputTokens) - t.input) * price.input / 1_000_000,
            output: (Double(u.outputTokens) - t.output) * price.output / 1_000_000,
            cacheRead: (Double(u.cacheReadTokens) - t.cacheRead) * price.cacheRead / 1_000_000,
            cacheWrite: (Double(u.cacheWriteTokens) - t.cacheWrite) * price.cacheWrite / 1_000_000)
        guard shape.total > 0 else {
            var b = estimated
            b.input += authoritative
            return b
        }
        let scale = authoritative / shape.total
        return RuntimesCostBreakdown(input: estimated.input + shape.input * scale, output: estimated.output + shape.output * scale,
                                     cacheRead: estimated.cacheRead + shape.cacheRead * scale, cacheWrite: estimated.cacheWrite + shape.cacheWrite * scale)
    }

    /// Cache reads at full input price minus what they cost at the cached rate.
    public func estimateCacheSavings(_ u: some RuntimesPriceable) -> Double {
        guard let price = resolve(u.model, provider: u.runtimesProvider) else { return 0 }
        return Double(u.cacheReadTokens) * (price.input - price.cacheRead) / 1_000_000
    }

    /// Sorted pricing keys that need a rate and have none.
    public func collectUnmappedModels<T: RuntimesPriceable>(_ rows: [T]) -> [String] {
        var set = Set<String>()
        for r in rows {
            guard !r.model.isEmpty, !isPriced(r.model, provider: r.runtimesProvider) else { continue }
            let t = Self.uncosted(r)
            let needsEstimate = t.input > 0 || t.output > 0 || t.cacheRead > 0 || t.cacheWrite > 0
            if !needsEstimate && (r.costUsdTicks ?? 0) > 0 { continue }
            set.insert(Self.pricingKey(r.model, provider: r.runtimesProvider))
        }
        return set.sorted()
    }
}

/// Number and currency formatting shared by the usage views.
public enum RuntimesFormat {
    static let tokenUnits: [(divisor: Double, suffix: String)] = [(1, ""), (1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]

    /// `1234` → `1.2K`, `999_999` → `1M`.
    public static func tokens(_ n: Double, locale: Locale = .current) -> String {
        let magnitude = abs(n)
        var unitIndex = max(tokenUnits.lastIndex { magnitude >= $0.divisor } ?? 0, 0)
        if unitIndex == 0 { return grouped(n, locale: locale) }
        var scaled = n / tokenUnits[unitIndex].divisor
        if abs(oneDecimal(scaled)) >= 1000 && unitIndex < tokenUnits.count - 1 {
            unitIndex += 1
            scaled = n / tokenUnits[unitIndex].divisor
        }
        return trimmed(oneDecimal(scaled)) + tokenUnits[unitIndex].suffix
    }

    public static func tokens(_ n: Int, locale: Locale = .current) -> String { tokens(Double(n), locale: locale) }

    static func oneDecimal(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    public static func grouped(_ n: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        f.maximumFractionDigits = 3
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Cents below $100, whole dollars above.
    public static func usd(_ n: Double) -> String {
        n >= 100 ? "$" + String(format: "%.0f", n) : "$" + String(format: "%.2f", n)
    }

    /// `$12.34` with two decimals, used by tooltips and cost lists.
    public static func usd2(_ n: Double) -> String { "$" + String(format: "%.2f", n) }

    /// Whole-percent cache hit rate over input-side tokens; 100 only for a
    /// complete hit.
    public static func cacheHitRatePercent(input: Int, cacheRead: Int, cacheWrite: Int) -> Int? {
        let side = input + cacheRead + cacheWrite
        guard side > 0 else { return nil }
        let pct = Double(cacheRead) / Double(side) * 100
        return pct == 100 ? 100 : min(Int(pct.rounded()), 99)
    }

    public static func pctChange(_ current: Double, _ previous: Double) -> Int? {
        guard previous > 0 else { return nil }
        return Int(((current - previous) / previous * 100).rounded())
    }

    /// Failure rate of terminal tasks — one decimal below 10%, a dash when
    /// nothing terminated.
    public static func rate(failed: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        let pct = Double(failed) / Double(total) * 100
        return pct >= 10 || pct == 0 ? "\(Int(pct.rounded()))%" : String(format: "%.1f%%", pct)
    }

    /// `"1h23m45.6s"`-style daemon uptime → `"1h 23m"`.
    public static func uptime(_ uptime: String?) -> String {
        guard let uptime, !uptime.isEmpty else { return "" }
        guard let m = uptime.firstMatch(of: /(?:(\d+)h)?(\d+)m/) else { return uptime }
        let h = m.1.map { "\($0)h " } ?? ""
        let out = "\(h)\(m.2)m".trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? uptime : out
    }
}
