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

    // MARK: - Default domain rules

    func testDefaultRulesDetectLaborRelation() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        用人单位为申请人缴纳社保并缴存公积金，且双方签订劳动合同。
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted, "劳动关系 keywords should be detected")
        XCTAssertTrue(verdict.finding.contains("劳动关系成立"),
                      "finding should name 劳动关系成立, got: \(verdict.finding)")
        XCTAssertEqual(verdict.findings.count, 3, "劳动合同/社保/公积金 should each match once")
    }

    func testDefaultRulesDetectWageStandard() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        月工资7550元，应发工资合计7550元，基本工资7000元。
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted)
        XCTAssertTrue(verdict.finding.contains("工资标准"),
                      "finding should name 工资标准, got: \(verdict.finding)")
        XCTAssertEqual(verdict.findings.count, 3, "月工资/应发工资/基本工资 should each match once")
    }

    func testDefaultRulesDetectWageArrears() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        用人单位拖欠工资且长期欠薪，劳动行政部门已作出行政处罚。
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted)
        XCTAssertTrue(verdict.finding.contains("欠薪证据"),
                      "finding should name 欠薪证据, got: \(verdict.finding)")
    }

    func testDefaultRulesDetectMixedEmployment() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        工资表由五建集团财务冉林夕制表，加盖五建集团公章，五建集团持股达海公司51%。
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted)
        XCTAssertTrue(verdict.finding.contains("混同用工"),
                      "finding should name 混同用工, got: \(verdict.finding)")
    }

    func testDefaultRulesDetectTerminationProcedure() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        申请人以被迫解除方式解除劳动关系，通知书已通过EMS送达。
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted)
        XCTAssertTrue(verdict.finding.contains("解除程序"),
                      "finding should name 解除程序, got: \(verdict.finding)")
    }

    func testDefaultRulesFindingsCarrySeverity() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        用人单位拖欠工资。
        """
        let result = try await llm.judge(prompt)
        XCTAssertTrue(result.contains(#""severity" : "high""#) || result.contains(#""severity":"high""#),
                      "high-severity rules should emit severity in findings JSON")
        let verdict = VerdictParser.parse(result)
        XCTAssertEqual(verdict.findings.count, 1, "拖欠 should match 欠薪证据 once")
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
