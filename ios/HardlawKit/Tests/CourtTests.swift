import XCTest
@testable import HardlawKit

final class CourtTests: XCTestCase {

    // MARK: - Helpers

    func makeCleanPassResponse() -> String {
        """
        {
            "finding": "none",
            "refuted": false,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [],
            "reasoning": "No violations found",
            "findings": []
        }
        """
    }

    func makeRefuteResponse(finding: String = "hate_speech", snippet: String = "bad word") -> String {
        """
        {
            "finding": "\(finding)",
            "refuted": true,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [{"source": "content", "location": "para 1", "snippet": "\(snippet)", "kind": "text"}],
            "reasoning": "Found banned text",
            "findings": [{"kind": "gap", "location": "content:1", "detail": "banned term '\(snippet)'"}]
        }
        """
    }

    func makeStatute(name: String = "hate_speech", requiredEvidence: [String] = []) -> Statute {
        Statute(
            name: name,
            description: "Prohibits hate speech",
            requiredEvidence: requiredEvidence,
            violations: [
                ViolationType(name: "hate_speech", severity: .critical, description: "Hate speech detected"),
            ]
        )
    }

    func makeProcedure(
        name: String = "content_review",
        maxRounds: Int = 10,
        stallThreshold: Int = 2,
        extraSteps: [Step] = []
    ) throws -> Procedure {
        try Procedure(
            name: name,
            steps: [
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech"],
                    transitions: ["not_refuted": "approved", "refuted": "rejected"]
                ),
                Step(name: "approved", kind: .code, transitions: [:]),
                Step(name: "rejected", kind: .code, transitions: [:]),
            ] + extraSteps,
            maxRounds: maxRounds,
            stallThreshold: stallThreshold
        )
    }

    func makeCourt(mock: MockLLM, procedure: Procedure? = nil, statutes: [Statute]? = nil) async -> Court {
        let proc: Procedure?
        let statutesList: [Statute]
        do {
            proc = try procedure ?? makeProcedure()
            statutesList = statutes ?? [makeStatute()]
        } catch {
            proc = nil
            statutesList = []
            XCTFail("Failed to create procedure: \(error)")
        }
        return Court(statutes: statutesList, procedure: proc, llm: mock)
    }

    // MARK: - Clean approval

    func testCleanApproval() async throws {
        let mock = MockLLM(responses: [makeCleanPassResponse()])
        let court = await makeCourt(mock: mock)
        let result = await court.hear(caseData: [
            "content": .string("hello world, this is fine"),
            "objective": .string("Audit for hate speech"),
        ])
        XCTAssertEqual(result.finalDisposition, .approved, "Expected approved, got \(result.finalDisposition)")
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertFalse(result.verdicts[0].refuted)
    }

    // MARK: - Refuted

    func testRefuted() async throws {
        let mock = MockLLM(responses: [makeRefuteResponse()])
        let court = await makeCourt(mock: mock)
        let result = await court.hear(caseData: [
            "content": .string("some bad word here"),
            "objective": .string("Audit for hate speech"),
        ])
        XCTAssertEqual(result.finalDisposition, .rejected, "Expected rejected, got \(result.finalDisposition)")
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertTrue(result.verdicts[0].refuted)
    }

    // MARK: - Refute then approve (fix loop)

    func testRefuteThenApproveFixLoop() async throws {
        let proc = try Procedure(
            name: "fix_loop",
            steps: [
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech"],
                    transitions: ["refuted": "fix", "not_refuted": "approved"]
                ),
                Step(
                    name: "fix",
                    kind: .code,
                    handler: { ctx in
                        ctx.data["content"] = .string("clean content after fix")
                    },
                    transitions: ["done": "verify"]
                ),
                Step(name: "approved", kind: .code, transitions: [:]),
            ]
        )
        let mock = MockLLM(responses: [
            makeRefuteResponse(snippet: "bad word"),
            makeCleanPassResponse(),
        ])
        let court = await makeCourt(mock: mock, procedure: proc)
        let result = await court.hear(caseData: [
            "content": .string("contains a bad word"),
            "objective": .string("Audit for hate speech"),
        ])
        XCTAssertEqual(result.finalDisposition, .approved, "Expected approved after fix, got \(result.finalDisposition)")
        XCTAssertEqual(result.verdicts.count, 2)
        XCTAssertTrue(result.verdicts[0].refuted) // first round: refuted
        XCTAssertFalse(result.verdicts[1].refuted) // second round: pass after fix
    }

    // MARK: - Blocked

    func testBlocked() async throws {
        let blockResponse = """
        {
            "finding": "severe_hate",
            "refuted": true,
            "confidence": "high",
            "blocking": "contradiction",
            "evidence_refs": [],
            "reasoning": "Severe violation — cannot continue",
            "findings": []
        }
        """
        let mock = MockLLM(responses: [blockResponse])
        let court = await makeCourt(mock: mock)
        let result = await court.hear(caseData: [
            "content": .string("extreme content"),
            "objective": .string("Audit"),
        ])
        XCTAssertEqual(result.finalDisposition, .blocked, "Expected blocked, got \(result.finalDisposition)")
    }

    // MARK: - No LLM

    func testNoLLM() async throws {
        let court = Court(statutes: [makeStatute()], procedure: try makeProcedure(), llm: nil)
        let result = await court.hear(caseData: [
            "content": .string("test"),
            "objective": .string("test"),
        ])
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(result.verdicts[0].finding, "no_llm")
        XCTAssertTrue(result.verdicts[0].refuted)
        XCTAssertTrue(result.verdicts[0].blocking)
    }

    // MARK: - No procedure

    func testNoProcedure() async {
        let court = Court(statutes: [makeStatute()], procedure: nil, llm: nil)
        let result = await court.hear()
        XCTAssertEqual(result.caseId, "no-procedure")
        XCTAssertEqual(result.finalDisposition, .rejected)
        XCTAssertTrue(result.reason.contains("No procedure"))
    }

    // MARK: - Stall detection

    func testStallDetection() async throws {
        // Same gap findings twice → stall
        let finding1 = makeRefuteResponse(finding: "same_gap", snippet: "problem")
        let finding2 = makeRefuteResponse(finding: "same_gap", snippet: "problem")
        let proc = try Procedure(
            name: "stall_test",
            steps: [
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech"],
                    transitions: ["refuted": "verify"] // self-loop
                ),
            ],
            stallThreshold: 2
        )
        let mock = MockLLM(responses: [finding1, finding2])
        let court = await makeCourt(mock: mock, procedure: proc)
        let result = await court.hear(caseData: [
            "content": .string("bad"),
            "objective": .string("test"),
        ])
        XCTAssertEqual(result.finalDisposition, .stalled, "Expected stalled, got \(result.finalDisposition)")
        XCTAssertEqual(result.verdicts.count, 2)
    }

    func testNoStallWithDifferentFindings() async throws {
        // Different findings each round → no stall → runs to max_rounds
        let proc = try Procedure(
            name: "no_stall_test",
            steps: [
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech"],
                    transitions: ["refuted": "verify"] // self-loop
                ),
            ],
            maxRounds: 3,
            stallThreshold: 2
        )
        let mock = MockLLM(responses: [
            makeRefuteResponse(finding: "gap_a", snippet: "problem1"),
            makeRefuteResponse(finding: "gap_b", snippet: "problem2"),
            makeRefuteResponse(finding: "gap_c", snippet: "problem3"),
        ])
        let court = await makeCourt(mock: mock, procedure: proc)
        let result = await court.hear(caseData: [
            "content": .string("bad"),
            "objective": .string("test"),
        ])
        XCTAssertEqual(result.finalDisposition, .maxRounds, "Expected maxRounds, got \(result.finalDisposition)")
        XCTAssertEqual(result.verdicts.count, 3)
    }

    // MARK: - Evidence enforcement

    func testEvidenceInsufficientForcesReject() async throws {
        // Statute requires "ocr_frame" evidence, but verdict doesn't cite it
        let statute = makeStatute(requiredEvidence: ["ocr_frame"])
        let proc = try Procedure(
            name: "evidence_test",
            steps: [
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech"],
                    transitions: ["not_refuted": "approved", "refuted": "rejected"]
                ),
                Step(name: "approved", kind: .code, transitions: [:]),
                Step(name: "rejected", kind: .code, transitions: [:]),
            ]
        )
        // LLM returns clean pass WITHOUT the required evidence
        let mock = MockLLM(responses: [makeCleanPassResponse()])
        let court = await makeCourt(mock: mock, procedure: proc, statutes: [statute])
        let result = await court.hear(caseData: [
            "content": .string("clean"),
            "objective": .string("test"),
        ])
        // Evidence insufficient → refuted=true forced, route=blocked → no transition → .blocked
        XCTAssertEqual(result.finalDisposition, .blocked, "Expected blocked due to insufficient evidence, got \(result.finalDisposition)")
        let v = result.verdicts[0]
        XCTAssertTrue(v.refuted, "Evidence insufficient should force refuted")
        XCTAssertNotNil(v.fallbackNote)
        XCTAssertTrue(v.fallbackNote!.contains("Evidence insufficient"))
    }

    func testEvidenceVerifiablePasses() async throws {
        // Statute requires "content" evidence → verdict cites it → verifiable → passes
        let statute = makeStatute(requiredEvidence: ["content"])
        let passWithEvidence = """
        {
            "finding": "none",
            "refuted": false,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [{"source": "content", "location": "para 1", "snippet": "hello world", "kind": "text"}],
            "reasoning": "All clean",
            "findings": []
        }
        """
        let mock = MockLLM(responses: [passWithEvidence])
        let court = await makeCourt(mock: mock, statutes: [statute])
        let result = await court.hear(caseData: [
            "content": .string("hello world this is fine"),
            "objective": .string("test"),
        ])
        XCTAssertEqual(result.finalDisposition, .approved, "Expected approved, got \(result.finalDisposition)")
        XCTAssertFalse(result.verdicts[0].refuted)
    }

    // MARK: - Max rounds

    func testMaxRounds() async throws {
        let proc = try Procedure(
            name: "loop_forever",
            steps: [
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech"],
                    transitions: ["not_refuted": "verify"] // infinite loop
                ),
            ],
            maxRounds: 3
        )
        let mock = MockLLM(responses: [
            makeCleanPassResponse(),
            makeCleanPassResponse(),
            makeCleanPassResponse(),
        ])
        let court = await makeCourt(mock: mock, procedure: proc)
        let result = await court.hear(caseData: [
            "content": .string("clean"),
            "objective": .string("test"),
        ])
        XCTAssertEqual(result.finalDisposition, .maxRounds)
        XCTAssertEqual(result.verdicts.count, 3)
    }
}
