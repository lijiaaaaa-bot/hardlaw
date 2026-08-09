import XCTest
@testable import HardlawKit

final class RuleBasedLLMTests: XCTestCase {

    // MARK: - RuleBasedLLM

    func testCleanContent() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        this is perfectly clean content with no issues at all
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertFalse(verdict.refuted, "Clean content should not be refuted")
        XCTAssertEqual(verdict.findings.count, 0, "Clean content should have no findings")
    }

    func testAmountMismatchHit() async throws {
        let llm = RuleBasedLLM(rules: [
            try! RuleBasedLLM.Rule(violationName: "amount_mismatch", pattern: #"\d+\.?\d*\s*元"#, severity: "high"),
        ])
        let prompt = """
        ## CASE DATA
        ### content
        工资标准为 7550元每月
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted, "Content with amount pattern should be refuted")
        XCTAssertFalse(verdict.findings.isEmpty, "Should have findings")
        XCTAssertTrue(verdict.evidenceRefs.allSatisfy { !$0.snippet.isEmpty },
                      "All evidence refs should have non-empty snippets")
    }

    func testMultipleAmounts() async throws {
        let llm = RuleBasedLLM(rules: [
            try! RuleBasedLLM.Rule(violationName: "amount", pattern: #"\d+\.?\d*\s*元"#, severity: "low"),
        ])
        let prompt = """
        ## CASE DATA
        ### content
        应发工资7550元，实发7450元，公积金基数7554元
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted, "Three amounts should be detected")
        XCTAssertEqual(verdict.findings.count, 3, "Should find 3 amount matches")
    }

    func testCustomRules() async throws {
        let customRule = try RuleBasedLLM.Rule(
            violationName: "custom_ban",
            pattern: #"\bSECRET_CODE_123\b"#,
            severity: "critical"
        )
        let llm = RuleBasedLLM(rules: [customRule])
        let prompt = """
        ## CASE DATA
        ### content
        the secret is SECRET_CODE_123 hidden here
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted)
        XCTAssertEqual(verdict.finding, "custom_ban")
    }

    // MARK: - Evidence Verifiability

    func testRuleBasedEvidenceIsVerifiable() async throws {
        let llm = RuleBasedLLM(rules: [
            try! RuleBasedLLM.Rule(violationName: "amount", pattern: #"\d+\.?\d*\s*元"#, severity: "low"),
        ])
        let prompt = """
        ## CASE DATA
        ### content
        月工资标准为7550元
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)

        var validator = EvidenceValidator()
        validator.addSource("content", "月工资标准为7550元")

        let (allValid, _) = validator.validateAll(verdict.evidenceRefs)
        XCTAssertTrue(allValid, "Rule-based evidence refs should be verifiable since snippets come from actual content")
    }


}
