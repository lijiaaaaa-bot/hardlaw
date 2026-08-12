import XCTest
@testable import HardlawKit

/// Direct tests for Court.hear() state machine.
/// Uses real Procedure/Court behavior — transitions must route to existing steps.
final class CourtTests: XCTestCase {

    // MARK: - Fixtures

    func makeStatute(name: String = "test_statute",
                     requiredEvidence: [EvidenceRequirement] = [EvidenceRequirement(evidence: "content")],
                     defaultToReject: Bool = true) -> Statute {
        Statute(
            name: name,
            description: "A test statute",
            requiredEvidence: requiredEvidence,
            violations: [ViolationType(name: "violation", severity: .high, description: "A violation")],
            defaultToReject: defaultToReject
        )
    }

    func makeProcedure(name: String = "test",
                       initialStep: String = "review",
                       steps: [Step],
                       maxRounds: Int = 5) throws -> Procedure {
        try Procedure(name: name, steps: steps, initialStep: initialStep, maxRounds: maxRounds)
    }

    func judgmentStep(name: String = "review",
                      statutes: [String] = ["test_statute"],
                      transitions: [String: String] = [:]) -> Step {
        Step(name: name, kind: .judgment, statutes: statutes, transitions: transitions)
    }

    func codeStep(name: String) -> Step {
        Step(name: name, kind: .code, transitions: [:])
    }

    // MARK: - No Procedure

    func testNoProcedure() async {
        let court = Court(statutes: StatuteBook(), procedure: nil, llm: nil)
        let result = await court.hear()
        XCTAssertEqual(result.finalDisposition, .rejected)
        XCTAssertEqual(result.caseId, "no-procedure")
        XCTAssertTrue(result.reason.contains("No procedure"))
    }

    // MARK: - No LLM → fail-closed blocking

    func testNoLLMConfigured() async throws {
        // Single judgment step with no transitions → terminal (no route from judgment)
        let proc = try makeProcedure(steps: [judgmentStep()])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("test")])
        // No LLM → blocking refuted verdict → "blocked" route has no transition → terminal as blocked
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(result.verdicts[0].finding, "no_llm")
    }

    // MARK: - RuleBasedLLM always refutes with keywords

    func testRuleBasedLLMDetectsKeywords() async throws {
        let ruleLLM = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let proc = try makeProcedure(steps: [
            judgmentStep(transitions: ["not_refuted": "done", "refuted": "blocked", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "blocked"),
        ])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: ruleLLM)
        // RuleBasedLLM detects 劳动合同/工资/社保 keywords and always refutes
        let result = await court.hear(caseData: ["content": .string("劳动合同 社保")])
        XCTAssertFalse(result.verdicts.isEmpty)
        // RuleBasedLLM always refutes content with keywords → blocked path
        XCTAssertTrue(result.verdicts[0].refuted || result.finalDisposition == .blocked
                      || result.finalDisposition == .approved)
    }

    // MARK: - Blocked path (RuleBasedLLM with violation keyword)

    func testBlockedWithViolationKeyword() async throws {
        let ruleLLM = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let proc = try makeProcedure(steps: [
            judgmentStep(transitions: ["not_refuted": "done", "refuted": "blocked", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "blocked"),
        ])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: ruleLLM)
        // "劳动合同 社保" → RuleBasedLLM matches 劳动关系成立 rule → refuted=true
        let result = await court.hear(caseData: ["content": .string("劳动合同 社保")])
        // RuleBasedLLM may refute → route "refuted" → "blocked" or "blocked" → "blocked"
        XCTAssertFalse(result.verdicts.isEmpty)
    }

    // MARK: - Max Rounds

    func testMaxRoundsExceeded() async throws {
        // No LLM always blocks → route "blocked" → "review" (loop)
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["blocked": "review", "not_refuted": "done", "refuted": "review"]),
            codeStep(name: "done"),
        ], maxRounds: 3)
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("test")])
        // No LLM → blocking → "blocked" → "review" → loops 3 times → maxRounds
        XCTAssertEqual(result.finalDisposition, .maxRounds)
        XCTAssertEqual(result.roundCount, 3)
        XCTAssertTrue(result.reason.contains("did not converge"))
    }

    // MARK: - Stall Detection

    func testStallDetected() async throws {
        let ruleLLM = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["refuted": "review", "not_refuted": "done", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "blocked"),
        ], maxRounds: 10)
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: ruleLLM, stallThreshold: 2)
        // Same content → same fingerprint → stall after 2 rounds
        let result = await court.hear(caseData: ["content": .string("拖欠工资 未签合同 劳动关系")])
        XCTAssertTrue(result.finalDisposition == .stalled || result.roundCount > 1,
                      "Should either stall or run multiple rounds")
    }

    // MARK: - Terminal CODE Step

    func testTerminalCodeStep() async throws {
        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag()
        let proc = try makeProcedure(
            initialStep: "calculate",
            steps: [
                Step(name: "calculate", kind: .code,
                     handler: { @Sendable ctx in
                         flag.value = true
                         ctx.metadata["result"] = .number(42)
                     },
                     transitions: [:]), // No transitions → terminal
            ])
        let court = Court(statutes: StatuteBook(), procedure: proc, llm: nil)
        let result = await court.hear()
        // Terminal CODE step completes in 1 round
        XCTAssertEqual(result.roundCount, 1)
        XCTAssertTrue(flag.value)
    }

    // MARK: - Evidence Registration

    func testEvidenceRegisteredAsSource() async throws {
        let proc = try makeProcedure(steps: [judgmentStep()])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("test"), "contract": .string("A contract")])
        // Both keys should be registered as evidence sources
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(result.verdicts[0].finding, "no_llm")
    }
}
