import Foundation

/// USD per million tokens.
public struct UsageModelPricing: Sendable, Hashable, Codable {
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

/// A usage row that can be priced (per-model token totals plus the optional
/// provider-authoritative cost split).
public protocol UsagePriceable {
    var model: String { get }
    var provider: String { get }
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

extension DashboardUsageDaily: UsagePriceable {}
extension DashboardUsageByAgent: UsagePriceable {}

public struct UsageCostBreakdown: Sendable, Hashable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0
    public var total: Double { input + output + cacheRead + cacheWrite }
}

/// The upstream runtimes pricing table and resolver (packages/views/runtimes/utils.ts).
public struct UsagePricing: Sendable {
    /// User-entered overrides keyed by pricing key (`cursor/auto`, `gpt-5.5-mini`).
    public var custom: [String: UsageModelPricing]

    public init(custom: [String: UsageModelPricing] = [:]) {
        self.custom = custom
    }

    /// Storage key of upstream's custom pricing store.
    public static let customPricingStorageKey = "multica_runtime_custom_pricing"

    /// Reads the persisted custom pricing (zustand `{state:{pricings}}`
    /// envelope or a bare map).
    public static func decodeCustomPricing(_ data: Data) -> [String: UsageModelPricing] {
        guard let value = try? JSONCoders.decoder.decode(JSONValue.self, from: data) else { return [:] }
        let map = value["state"]?["pricings"] ?? value["pricings"] ?? value
        guard case .object(let entries) = map else { return [:] }
        var out: [String: UsageModelPricing] = [:]
        for (key, entry) in entries {
            guard let input = entry["input"]?.doubleValue, let output = entry["output"]?.doubleValue else { continue }
            out[key] = UsageModelPricing(input: input, output: output,
                                         cacheRead: entry["cacheRead"]?.doubleValue ?? 0,
                                         cacheWrite: entry["cacheWrite"]?.doubleValue ?? 0)
        }
        return out
    }

    static let ticksPerUSD = 10_000_000_000.0

    private static func p(_ i: Double, _ o: Double, _ r: Double, _ w: Double) -> UsageModelPricing {
        UsageModelPricing(input: i, output: o, cacheRead: r, cacheWrite: w)
    }

    public static let table: [String: UsageModelPricing] = [
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

    private static let candidateCache = Locked<[String: [String]]>([:])

    /// Lookup candidates in priority order: raw, provider-stripped, Anthropic
    /// dot→dash, context tag stripped, then the date-stripped forms.
    public static func canonicalCandidates(_ model: String) -> [String] {
        if let hit = candidateCache.current[model] { return hit }
        var seen = Set<String>()
        var out: [String] = []
        func push(_ s: String) {
            guard !s.isEmpty, !seen.contains(s) else { return }
            seen.insert(s)
            out.append(s)
        }
        let noProvider = stripProvider(model)
        let dashed = noProvider.hasPrefix("claude-") ? noProvider.replacingOccurrences(of: ".", with: "-") : noProvider
        let noTag = stripContextTag(dashed)
        push(model)
        push(noProvider)
        push(dashed)
        push(noTag)
        push(stripDate(model))
        push(stripDate(noProvider))
        push(stripDate(dashed))
        push(stripDate(noTag))
        candidateCache.withLock { $0[model] = out }
        return out
    }

    static func stripProvider(_ s: String) -> String {
        var out = Substring(s)
        while true {
            guard let sep = out.firstIndex(where: { $0 == "/" || $0 == ":" }), sep > out.startIndex else { break }
            let head = out[out.startIndex..<sep]
            guard let first = head.first, first.isASCII, first.isLetter,
                  head.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { break }
            out = out[out.index(after: sep)...]
        }
        return String(out)
    }

    static func stripContextTag(_ s: String) -> String {
        guard s.hasSuffix("]"), let open = s.lastIndex(of: "["), s.index(after: open) < s.index(before: s.endIndex) else { return s }
        return String(s[..<open])
    }

    static func stripDate(_ s: String) -> String {
        if s.hasSuffix("-latest") { return String(s.dropLast(7)) }
        guard let dash = s.lastIndex(of: "-") else { return s }
        let tail = s[s.index(after: dash)...]
        let compact = tail.count == 8 && tail.hasPrefix("20") && tail.allSatisfy(\.isNumber)
        if compact { return String(s[..<dash]) }
        // -YYYY-MM-DD
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count >= 4 {
            let y = parts[parts.count - 3], m = parts[parts.count - 2], d = parts[parts.count - 1]
            if y.count == 4, y.hasPrefix("20"), m.count == 2, d.count == 2,
               (y + m + d).allSatisfy(\.isNumber) {
                return parts.dropLast(3).joined(separator: "-")
            }
        }
        return s
    }

    static func normalizeProvider(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func qualify(_ provider: String, _ key: String) -> String {
        key.hasPrefix(provider + "/") ? key : "\(provider)/\(key)"
    }

    static func candidates(_ model: String, provider: String) -> [String] {
        let base = canonicalCandidates(model)
        let p = normalizeProvider(provider)
        guard !p.isEmpty else { return base }
        return base.map { qualify(p, $0) } + base
    }

    public static func pricingKey(_ model: String, provider: String) -> String {
        let p = normalizeProvider(provider)
        return p.isEmpty ? model : qualify(p, model)
    }

    public func resolve(_ model: String, provider: String = "") -> UsageModelPricing? {
        guard !model.isEmpty else { return nil }
        let candidates = Self.candidates(model, provider: provider)
        for c in candidates {
            if let hit = Self.table[c] { return hit }
        }
        for c in candidates {
            if let hit = custom[c] { return hit }
        }
        return nil
    }

    public func isPriced(_ model: String, provider: String = "") -> Bool {
        resolve(model, provider: provider) != nil
    }

    private struct Tokens { var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0 }

    private func uncosted(_ u: some UsagePriceable) -> Tokens {
        guard let input = u.uncostedInputTokens else {
            if (u.costUsdTicks ?? 0) > 0 { return Tokens() }
            return Tokens(input: Double(u.inputTokens), output: Double(u.outputTokens),
                          cacheRead: Double(u.cacheReadTokens), cacheWrite: Double(u.cacheWriteTokens))
        }
        return Tokens(input: Double(input), output: Double(u.uncostedOutputTokens ?? 0),
                      cacheRead: Double(u.uncostedCacheReadTokens ?? 0), cacheWrite: Double(u.uncostedCacheWriteTokens ?? 0))
    }

    /// Provider-charged cost plus a rate-table estimate for the uncharged rest.
    public func estimateCost(_ u: some UsagePriceable) -> Double {
        let authoritative = (u.costUsdTicks ?? 0) / Self.ticksPerUSD
        guard let price = resolve(u.model, provider: u.provider) else { return authoritative }
        let t = uncosted(u)
        return authoritative + (t.input * price.input + t.output * price.output
            + t.cacheRead * price.cacheRead + t.cacheWrite * price.cacheWrite) / 1_000_000
    }

    /// Per-token-type split of `estimateCost`; the authoritative half is
    /// spread in the proportions the rate table would have charged.
    public func estimateCostBreakdown(_ u: some UsagePriceable) -> UsageCostBreakdown {
        let authoritative = (u.costUsdTicks ?? 0) / Self.ticksPerUSD
        guard let price = resolve(u.model, provider: u.provider) else {
            return UsageCostBreakdown(input: authoritative)
        }
        let t = uncosted(u)
        let b = UsageCostBreakdown(input: t.input * price.input / 1_000_000, output: t.output * price.output / 1_000_000,
                                   cacheRead: t.cacheRead * price.cacheRead / 1_000_000,
                                   cacheWrite: t.cacheWrite * price.cacheWrite / 1_000_000)
        guard authoritative > 0 else { return b }
        let shape = UsageCostBreakdown(
            input: (Double(u.inputTokens) - t.input) * price.input / 1_000_000,
            output: (Double(u.outputTokens) - t.output) * price.output / 1_000_000,
            cacheRead: (Double(u.cacheReadTokens) - t.cacheRead) * price.cacheRead / 1_000_000,
            cacheWrite: (Double(u.cacheWriteTokens) - t.cacheWrite) * price.cacheWrite / 1_000_000)
        guard shape.total > 0 else {
            var out = b
            out.input += authoritative
            return out
        }
        let scale = authoritative / shape.total
        return UsageCostBreakdown(input: b.input + shape.input * scale, output: b.output + shape.output * scale,
                                  cacheRead: b.cacheRead + shape.cacheRead * scale,
                                  cacheWrite: b.cacheWrite + shape.cacheWrite * scale)
    }
}
