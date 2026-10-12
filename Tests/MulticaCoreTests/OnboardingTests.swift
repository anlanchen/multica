import XCTest
@testable import MulticaCore

final class OnboardingTests: XCTestCase {
    func testStepOrder() {
        XCTAssertEqual(OnboardingStep.order, [.aboutYou, .workspace, .runtime])
        XCTAssertEqual(OnboardingStep.aboutYou.next, .workspace)
        XCTAssertNil(OnboardingStep.runtime.next)
        XCTAssertEqual(OnboardingStep.aboutYou.previous, .welcome)
        XCTAssertEqual(OnboardingStep.runtime.previous, .workspace)
    }

    func testQuestionnaireResumeCoercesLegacyShapes() {
        let stored: [String: JSONValue] = [
            "source": "search", "use_case": .array(["ship_code", ""]), "role": "engineer",
            "role_skipped": true, "use_case_skipped": true,
        ]
        let q = OnboardingQuestionnaire(resuming: stored)
        XCTAssertEqual(q.source, ["search"])
        XCTAssertEqual(q.useCase, ["ship_code"])
        XCTAssertEqual(q.role, "engineer")
        XCTAssertFalse(q.roleSkipped)
        XCTAssertFalse(q.useCaseSkipped)
        XCTAssertTrue(OnboardingQuestionnaire(stored: stored).roleSkipped)
        XCTAssertEqual(q.json["version"], .number(2))
    }

    func testAboutYouAnswering() {
        var q = OnboardingQuestionnaire()
        XCTAssertFalse(q.canContinueAboutYou)
        q.pickRole("other")
        XCTAssertFalse(q.roleAnswered)
        q.roleOther = "teacher"
        XCTAssertTrue(q.roleAnswered)
        q.pickRole("designer")
        XCTAssertNil(q.roleOther)
        q.toggleUseCase("other")
        XCTAssertFalse(q.useCaseAnswered)
        q.toggleUseCase("ship_code")
        XCTAssertTrue(q.useCaseAnswered)
        q.toggleUseCase("ship_code")
        q.useCaseOther = "x"
        q.toggleUseCase("other")
        XCTAssertEqual(q.useCase, [])
        XCTAssertNil(q.useCaseOther)
        q.stampUnanswered()
        XCTAssertTrue(q.useCaseSkipped)
        XCTAssertFalse(q.roleSkipped)
    }

    func testSourcePatchKeepsOtherAnswers() {
        let stored: [String: JSONValue] = ["role": "founder", "use_case": "evaluate", "use_case_other": ""]
        let q = OnboardingQuestionnaire.sourcePatch(stored: stored, source: ["other"], sourceOther: "podcast", sourceSkipped: false)
        XCTAssertEqual(q.role, "founder")
        XCTAssertEqual(q.useCase, ["evaluate"])
        XCTAssertNil(q.useCaseOther)
        XCTAssertEqual(q.source, ["other"])
        XCTAssertEqual(q.sourceOther, "podcast")
    }

    func testSourceBackfillGate() {
        XCTAssertFalse(OnboardingSourceBackfill.needed(onboardedAt: nil, questionnaire: nil, dismissCount: 0))
        XCTAssertTrue(OnboardingSourceBackfill.needed(onboardedAt: "2026-01-01", questionnaire: nil, dismissCount: 0))
        XCTAssertFalse(OnboardingSourceBackfill.needed(onboardedAt: "2026-01-01", questionnaire: nil, dismissCount: 3))
        XCTAssertFalse(OnboardingSourceBackfill.needed(onboardedAt: "x", questionnaire: ["source_skipped": true], dismissCount: 0))
        XCTAssertFalse(OnboardingSourceBackfill.needed(onboardedAt: "x", questionnaire: ["source": .array(["search"])], dismissCount: 0))
        XCTAssertFalse(OnboardingSourceBackfill.needed(onboardedAt: "x", questionnaire: ["source": "search"], dismissCount: 0))
        XCTAssertTrue(OnboardingSourceBackfill.needed(onboardedAt: "x", questionnaire: ["source": .array([])], dismissCount: 2))
    }

    func testSlugRules() {
        XCTAssertTrue(OnboardingSlug.isValid("acme-labs-2"))
        XCTAssertFalse(OnboardingSlug.isValid("Acme"))
        XCTAssertFalse(OnboardingSlug.isValid("-acme"))
        XCTAssertFalse(OnboardingSlug.isValid("a--b"))
        XCTAssertTrue(OnboardingSlug.isReserved("inbox"))
        XCTAssertFalse(OnboardingSlug.isReserved("acme"))
        let identity: (String) -> String = { _ in "zhi zhu xia" }
        XCTAssertEqual(OnboardingSlug.fromName("Acme  Inc!", locale: "en", romanize: identity), "acme-inc")
        XCTAssertEqual(OnboardingSlug.fromName("蜘蛛侠 Team", locale: "en", romanize: identity), "zhizhuxia-team")
        XCTAssertEqual(OnboardingSlug.fromName("蜘蛛侠", locale: "ja", romanize: identity), "")
        XCTAssertEqual(OnboardingSlug.fromName("東京タワー", locale: "en", romanize: identity), "")
        XCTAssertEqual(OnboardingSlug.issuePrefix("my-lab-2026"), "MYLA")
        XCTAssertEqual(OnboardingSlug.issuePrefix(""), "")
        XCTAssertEqual(OnboardingSlug.normalizePrefix("ab-c 12345678901"), "ABC1234567")
        XCTAssertEqual(OnboardingSlug.urlHost(nil), "multica.ai")
        XCTAssertEqual(OnboardingSlug.urlHost("https://pm.example.com/app"), "pm.example.com")
        XCTAssertEqual(OnboardingSlug.urlHost("pm.example.com/app"), "pm.example.com")
        XCTAssertEqual(OnboardingSlug.urlHost("http://localhost:3000"), "localhost:3000")
    }

    func testRandomCelestial() {
        let r = OnboardingSlug.randomCelestial(locale: "fr") { 0 }
        XCTAssertEqual(r.name, "Alpha du Centaure")
        XCTAssertEqual(r.slug, "alpha-centauri-aaaa")
        XCTAssertTrue(OnboardingSlug.isValid(OnboardingSlug.randomCelestial(locale: "en").slug))
    }

    func testTemplates() {
        XCTAssertEqual(OnboardingTemplates.contentLanguage("fr"), "en")
        XCTAssertEqual(OnboardingTemplates.contentLanguage("zh-Hans"), "zh")
        for lang in ["en", "zh", "ko", "ja"] {
            XCTAssertFalse(OnboardingTemplates.installRuntimeIssueBody[lang, default: ""].isEmpty)
            XCTAssertNotNil(OnboardingTemplates.mikaChatTitle[lang])
        }
    }
}
