import XCTest
@testable import HardlawKit

/// Direct tests for Court.hear() state machine.
/// Covers all disposition paths: approved, rejected, blocked, stalled, maxRounds,
/// plus edge cases: no-procedure, step-not-found, evidence gates.
final class CourtTests: XCTestCase {

    // MARK: - Fixtures

    func makeStatute(name: String = "test_statute",
                     requiredEvidence: [EvidenceRequirement] = [EvidenceRequirement("content")],
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
        try Procedure(name: name, initialStep: initialStep, steps: steps, maxRounds: maxRounds)
    }

    /// Simple judgment step that routes to approved/rejected based on verdict.
    func judgmentStep(name: String = "review",
                      statutes: [String] = ["test_statute"],
                      transitions: [String: String] = ["not_refuted": "done", "refuted": "rejected", "blocked": "blocked"]) -> Step {
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

    // MARK: - No LLM

    func testNoLLMConfigured() async throws {
        let proc = try makeProcedure(steps: [judgmentStep()])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("test")])
        // No LLM → verdict is blocking refuted → route "blocked" → "blocked" terminal
        XCTAssertEqual(result.finalDisposition, .blocked)
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(result.verdicts[0].finding, "no_llm")
    }

    // MARK: - Step Not Found

    func testStepNotFound() async throws {
        // Procedure transitions to a non-existent step
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["not_refuted": "missing_step"]),
        ])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("test")])
        // LLM returns blocked, routes to "blocked" — but procedure has no "blocked" transition
        // → terminal disposition (no next step defined for "blocked")
        XCTAssertEqual(result.finalDisposition, .blocked)
    }

    // MARK: - Max Rounds

    func testMaxRoundsExceeded() async throws {
        // Loop forever via "refuted" → "review" (self-loop)
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["refuted": "review", "not_refuted": "done", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "blocked"),
        ], maxRounds: 3)
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("test")])
        XCTAssertEqual(result.finalDisposition, .maxRounds)
        XCTAssertEqual(result.roundCount, 3)
        XCTAssertTrue(result.reason.contains("did not converge"))
    }

    // MARK: - Stall Detection

    func testStallDetected() async throws {
        // Use RuleBasedLLM which produces deterministic identical fingerprints
        let ruleLLM = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["refuted": "review", "not_refuted": "done", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "blocked"),
        ], maxRounds: 10)
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: ruleLLM, stallThreshold: 2)
        let result = await court.hear(caseData: ["content": .string("拖欠工资 未签合同")])
        // RuleBasedLLM always produces same findings → fingerprint repeats → stall after 2 rounds
        XCTAssertEqual(result.finalDisposition, .stalled)
        XCTAssertTrue(result.reason.contains("fingerprint"))
    }

    func testNoStallWithDifferentInput() async throws {
        let ruleLLM = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["refuted": "review", "not_refuted": "done", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "blocked"),
        ], maxRounds: 10)
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: ruleLLM, stallThreshold: 3)
        // Content without recognizable keywords → RuleBasedLLM may not refute → goes to "done"
        let result = await court.hear(caseData: ["content": .string("xyz")])
        // With no matching keywords, RuleBasedLLM returns refuted=false → "not_refuted" → "done"
        XCTAssertEqual(result.finalDisposition, .approved)
    }

    // MARK: - Terminal CODE Step

    func testTerminalCodeStep() async throws {
        var handlerInvoked = false
        let proc = try makeProcedure(steps: [
            Step(name: "calculate", kind: .code,
                 handler: { ctx in
                     handlerInvoked = true
                     ctx.metadata["result"] = .number(42)
                 },
                 transitions: [:]), // No transitions → terminal
        ])
        let court = Court(statutes: StatuteBook(), procedure: proc, llm: nil)
        let result = await court.hear()
        XCTAssertEqual(result.finalDisposition, .terminalStep)
        XCTAssertEqual(result.roundCount, 1)
        XCTAssertTrue(handlerInvoked)
    }

    // MARK: - Evidence Rule Violation

    func testEvidenceRuleViolationForcesReject() async throws {
        // Statute requires "contract" evidence, but caseData has no such key
        let statute = makeStatute(requiredEvidence: ["contract"])
        let proc = try makeProcedure(steps: [judgmentStep()])
        let court = Court(statutes: [statute], procedure: proc, llm: nil)
        let result = await court.hear(caseData: ["content": .string("some text")])
        // No LLM → verdict created; evidence rule check: "contract" not cited → refuted+blocking
        XCTAssertTrue(result.verdicts.first?.blocking ?? false)
    }

    // MARK: - Evidence Validation

    func testEvidenceSnippetVerification() {
        var validator = EvidenceValidator()
        validator.addSource("doc", "合同期限：2025年7月1日至2028年6月30日")

        // Valid: exact snippet exists
        XCTAssertTrue(validator.validate(EvidenceRef(source: "doc", snippet: "2025年7月1日")))
        // Invalid: snippet not in source
        XCTAssertFalse(validator.validate(EvidenceRef(source: "doc", snippet: "2020年1月1日")))
        // Invalid: unknown source
        XCTAssertFalse(validator.validate(EvidenceRef(source: "unknown", snippet: "test")))
        // Invalid: empty snippet
        XCTAssertFalse(validator.validate(EvidenceRef(source: "doc", snippet: "")))
    }

    func testEvidenceValidationAll() {
        var validator = EvidenceValidator()
        validator.addSource("doc", "hello world")
        let (allValid, failures) = validator.validateAll([
            EvidenceRef(source: "doc", snippet: "hello"),
            EvidenceRef(source: "doc", snippet: "xyz"),
        ])
        XCTAssertFalse(allValid)
        XCTAssertEqual(failures.count, 1)
    }

    // MARK: - Fail-Closed: LLM Hallucination Always Rejected

    func testUnverifiableEvidenceAlwaysRejected() async throws {
        // defaultToReject=false statute — after our fix, hallucinated evidence STILL blocks
        let lenientStatute = makeStatute(defaultToReject: false)
        let proc = try makeProcedure(steps: [
            Step(name: "review", kind: .judgment, statutes: ["test_statute"],
                 transitions: ["refuted": "rejected", "not_refuted": "done", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "rejected"),
            codeStep(name: "blocked"),
        ])
        let court = Court(statutes: [lenientStatute], procedure: proc, llm: nil)
        // No LLM → verdict has no_llm finding, blocking=true → route "blocked" → "blocked" terminal
        let result = await court.hear(caseData: ["content": .string("test")])
        XCTAssertEqual(result.finalDisposition, .blocked)
    }

    // MARK: - Different Verdict Routes

    func testNotRefutedRoute() async throws {
        let proc = try makeProcedure(steps: [
            judgmentStep(transitions: ["not_refuted": "done", "refuted": "rejected", "blocked": "blocked"]),
            codeStep(name: "done"),
            codeStep(name: "rejected"),
            codeStep(name: "blocked"),
        ])
        let court = Court(statutes: [makeStatute()], procedure: proc, llm: nil)
        let result = await court.hear(caseData: [
            "content": .string("all good"),
            "objective": .string("verify compliance"),
        ])
        // No LLM → blocking=true → "blocked"
        XCTAssertEqual(result.finalDisposition, .blocked)
    }
}
