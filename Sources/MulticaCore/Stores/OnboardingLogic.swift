import Foundation

/// Onboarding steps. `welcome` is a product intro, not a persisted step.
public enum OnboardingStep: String, Sendable, Hashable, CaseIterable {
    case welcome
    case aboutYou = "about_you"
    case workspace
    case runtime

    /// The persisted steps in order (upstream ONBOARDING_STEP_ORDER).
    public static let order: [OnboardingStep] = [.aboutYou, .workspace, .runtime]

    public var index: Int? { Self.order.firstIndex(of: self) }

    public var next: OnboardingStep? {
        guard let i = index, i + 1 < Self.order.count else { return nil }
        return Self.order[i + 1]
    }

    /// The step Back leads to: About you returns to Welcome.
    public var previous: OnboardingStep {
        guard let i = index, i > 0 else { return .welcome }
        return Self.order[i - 1]
    }
}

/// Exit path sent to `POST /api/me/onboarding/complete`.
public enum OnboardingCompletionPath: String, Sendable {
    case full
    case runtimeSkipped = "runtime_skipped"
    case cloudWaitlist = "cloud_waitlist"
    case skipExisting = "skip_existing"
    case inviteAccept = "invite_accept"
}

/// `user.onboarding_questionnaire` (version 2). `source` and `use_case` are
/// arrays; older rows stored a bare string, which is read as one element.
public struct OnboardingQuestionnaire: Sendable, Hashable {
    public var source: [String] = []
    public var sourceOther: String?
    public var sourceSkipped = false
    public var role: String?
    public var roleOther: String?
    public var roleSkipped = false
    public var useCase: [String] = []
    public var useCaseOther: String?
    public var useCaseSkipped = false

    public init() {}

    /// Re-entry pre-fills answered slots but treats every `*_skipped` as
    /// fresh (upstream `mergeQuestionnaire`).
    public init(resuming stored: [String: JSONValue]) {
        self.init(stored: stored)
        sourceSkipped = false
        roleSkipped = false
        useCaseSkipped = false
    }

    public init(stored: [String: JSONValue]) {
        source = Self.strings(stored["source"])
        sourceOther = Self.string(stored["source_other"])
        sourceSkipped = stored["source_skipped"]?.boolValue == true
        role = Self.string(stored["role"])
        roleOther = Self.string(stored["role_other"])
        roleSkipped = stored["role_skipped"]?.boolValue == true
        useCase = Self.strings(stored["use_case"])
        useCaseOther = Self.string(stored["use_case_other"])
        useCaseSkipped = stored["use_case_skipped"]?.boolValue == true
    }

    static func strings(_ v: JSONValue?) -> [String] {
        switch v {
        case .array(let a): return a.compactMap { $0.stringValue }.filter { !$0.isEmpty }
        case .string(let s) where !s.isEmpty: return [s]
        default: return []
        }
    }

    static func string(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue, !s.isEmpty else { return nil }
        return s
    }

    public var json: [String: JSONValue] {
        [
            "source": JSONValue(source),
            "source_other": JSONValue(sourceOther),
            "source_skipped": .bool(sourceSkipped),
            "role": JSONValue(role),
            "role_other": JSONValue(roleOther),
            "role_skipped": .bool(roleSkipped),
            "use_case": JSONValue(useCase),
            "use_case_other": JSONValue(useCaseOther),
            "use_case_skipped": .bool(useCaseSkipped),
            "version": .number(2),
        ]
    }

    /// A role counts once picked; "other" only once its text is filled.
    public var roleAnswered: Bool {
        guard let role else { return false }
        return role != "other" || !(roleOther ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A lone "other" use case only counts once its text is filled.
    public var useCaseAnswered: Bool {
        guard !useCase.isEmpty else { return false }
        return useCase.contains { $0 != "other" } || !(useCaseOther ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var canContinueAboutYou: Bool { roleAnswered || useCaseAnswered }

    public mutating func pickRole(_ slug: String) {
        if slug == "other" {
            role = "other"
        } else {
            role = slug
            roleOther = nil
        }
        roleSkipped = false
    }

    public mutating func toggleUseCase(_ slug: String) {
        if useCase.contains(slug) {
            useCase.removeAll { $0 == slug }
            if slug == "other" { useCaseOther = nil }
        } else {
            useCase.append(slug)
            useCaseSkipped = false
        }
    }

    /// Continue: any group left unanswered is stamped as a decline.
    public mutating func stampUnanswered() {
        if !roleAnswered {
            role = nil
            roleOther = nil
            roleSkipped = true
        }
        if !useCaseAnswered {
            useCase = []
            useCaseOther = nil
            useCaseSkipped = true
        }
    }

    public mutating func skipAboutYou() {
        role = nil
        roleOther = nil
        roleSkipped = true
        useCase = []
        useCaseOther = nil
        useCaseSkipped = true
    }

    /// The PATCH replaces the JSON wholesale, so the source backfill keeps
    /// every other stored answer and overlays only the source slots.
    public static func sourcePatch(stored: [String: JSONValue]?, source: [String], sourceOther: String?, sourceSkipped: Bool) -> OnboardingQuestionnaire {
        var q = OnboardingQuestionnaire(stored: stored ?? [:])
        q.source = source
        q.sourceOther = sourceOther
        q.sourceSkipped = sourceSkipped
        return q
    }
}

/// When to ask an onboarded user where they heard about Multica.
public enum OnboardingSourceBackfill {
    public static let maxDismissals = 3
    public static let minAgentDoneIssues = 3

    public static func needed(onboardedAt: String?, questionnaire: [String: JSONValue]?, dismissCount: Int) -> Bool {
        guard let onboardedAt, !onboardedAt.isEmpty else { return false }
        if dismissCount >= maxDismissals { return false }
        guard let q = questionnaire, !q.isEmpty else { return true }
        if q["source_skipped"]?.boolValue == true { return false }
        switch q["source"] {
        case .array(let a): return a.isEmpty
        case .string(let s): return s.isEmpty
        default: return true
        }
    }
}

/// Runtime labels (upstream runtimes/display.ts): the custom alias when set,
/// with the provider re-attached so the backing CLI stays visible.
public enum OnboardingRuntimeLabel {
    static let providerNames: [String: String] = [
        "codearts": "CodeArts", "dsh": "DeepSeek Harness", "qoderclicn": "Qoder CN", "traecli": "Trae",
        "qwen": "Qwen Code", "qwenpaw": "QwenPaw", "mcode": "MiniMax Code", "omp": "Oh-My-Pi", "zeroclaw": "ZeroClaw",
    ]

    public static func providerName(_ provider: String) -> String {
        providerNames[provider] ?? (provider.prefix(1).uppercased() + provider.dropFirst())
    }

    public static func label(name: String, customName: String?, provider: String) -> String {
        let custom = customName?.trimmingCharacters(in: .whitespaces) ?? ""
        let p = provider.trimmingCharacters(in: .whitespaces)
        if custom.isEmpty { return name }
        return p.isEmpty ? custom : "\(custom) (\(providerName(p)))"
    }
}

/// Workspace URL and issue-prefix rules (upstream workspace/slug.ts).
public enum OnboardingSlug {
    public static func isValid(_ slug: String) -> Bool {
        slug.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    public static func isReserved(_ slug: String) -> Bool {
        OnboardingWorkspaceData.reservedSlugs.contains(slug.lowercased())
    }

    /// Han characters are romanized for Chinese names only: kana in the name
    /// or a Japanese/Korean UI means the reading isn't Mandarin, so those
    /// names yield an empty slug for the user to fill in. `romanize`
    /// converts one run of Han characters to toneless pinyin.
    public static func fromName(_ name: String, locale: String, romanize: (String) -> String) -> String {
        var text = name
        if shouldRomanize(name, locale: locale) {
            text = replacingHanRuns(in: name) { run in
                " " + romanize(run).filter { !$0.isWhitespace && $0 != "'" } + " "
            }
        }
        var out = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(s.value) || (0x4E00...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
    }

    static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(s.value) || (0x309B...0x30FF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value)
    }

    static func shouldRomanize(_ name: String, locale: String) -> Bool {
        if locale == "ja" || locale == "ko" { return false }
        return !name.unicodeScalars.contains(where: isKana)
    }

    static func replacingHanRuns(in name: String, _ transform: (String) -> String) -> String {
        var out = ""
        var run = String.UnicodeScalarView()
        func flush() {
            if !run.isEmpty {
                out += transform(String(run))
                run = String.UnicodeScalarView()
            }
        }
        for s in name.unicodeScalars {
            if isHan(s) {
                run.append(s)
            } else {
                flush()
                out.unicodeScalars.append(s)
            }
        }
        flush()
        return out
    }

    /// The server's default prefix: the slug's first four alphanumerics,
    /// uppercased.
    public static func issuePrefix(_ slug: String) -> String {
        String(slug.trimmingCharacters(in: .whitespaces).lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(4)).uppercased()
    }

    /// Letters and digits only, uppercased, at most ten.
    public static func normalizePrefix(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
    }

    /// Host shown before the slug: the deployment's app URL, else the brand
    /// host.
    public static func urlHost(_ appURL: String?) -> String {
        let brand = "multica.ai"
        guard let trimmed = appURL?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return brand }
        if let host = URL(string: trimmed)?.host, !host.isEmpty {
            if let port = URL(string: trimmed)?.port { return "\(host):\(port)" }
            return host
        }
        var bare = trimmed
        if let r = bare.range(of: "://") { bare = String(bare[r.upperBound...]) }
        if let cut = bare.firstIndex(where: { "/?#".contains($0) }) { bare = String(bare[..<cut]) }
        bare = bare.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? brand : bare
    }

    /// A localized celestial name with a stable English slug plus a random
    /// four-character suffix.
    public static func randomCelestial(locale: String, random: () -> Double = { Double.random(in: 0..<1) }) -> (name: String, slug: String) {
        let names = OnboardingWorkspaceData.celestialNames
        let pick = names[min(names.count - 1, Int(random() * Double(names.count)))]
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var suffix = ""
        for _ in 0..<4 { suffix.append(alphabet[min(alphabet.count - 1, Int(random() * Double(alphabet.count)))]) }
        return (pick.names[locale] ?? pick.names["en"] ?? pick.slugBase, "\(pick.slugBase)-\(suffix)")
    }
}
