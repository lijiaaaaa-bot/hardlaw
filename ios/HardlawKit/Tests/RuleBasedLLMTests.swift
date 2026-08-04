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

    func testBanListHit() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        this contains a damn bad word
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        XCTAssertTrue(verdict.refuted, "Content with banned term should be refuted")
        XCTAssertFalse(verdict.findings.isEmpty, "Should have findings")
        // Verify evidence refs have snippets
        XCTAssertTrue(verdict.evidenceRefs.allSatisfy { !$0.snippet.isEmpty },
                      "All evidence refs should have non-empty snippets")
    }

    func testPIILeakDetection() async throws {
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        user email is test@example.com and phone 555-123-4567
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)
        // PII patterns matches email and phone → refuted
        XCTAssertTrue(verdict.refuted, "PII content should be refuted")
        XCTAssertTrue(verdict.findings.count >= 1, "Should find at least email PII")
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
        // RuleBasedLLM uses actual content substrings as snippets → always verifiable
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        this email user@domain.com should be detected
        """
        let result = try await llm.judge(prompt)
        let verdict = VerdictParser.parse(result)

        // Register the content as a source
        var validator = EvidenceValidator()
        validator.addSource("content", "this email user@domain.com should be detected")

        let (allValid, _) = validator.validateAll(verdict.evidenceRefs)
        XCTAssertTrue(allValid, "All rule-based evidence refs should be verifiable since snippets come from actual content")
    }

    // MARK: - CapabilityDetector

    func testCapabilityDetectorRecommendsBackend() {
        let backend = CapabilityDetector.recommendedBackend()
        // On simulator/CI, this will fall back to ruleBased (insufficient memory)
        XCTAssertTrue([.ruleBased, .mlxLLM].contains(backend))
    }
}
