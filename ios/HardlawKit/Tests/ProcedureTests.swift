import XCTest
@testable import HardlawKit

final class ProcedureTests: XCTestCase {

    // MARK: - Step

    func testStepNextStep() {
        let step = Step(name: "verify", kind: .judgment, transitions: ["refuted": "rejected", "not_refuted": "approved"])
        XCTAssertEqual(step.nextStep("refuted"), "rejected")
        XCTAssertEqual(step.nextStep("not_refuted"), "approved")
        XCTAssertNil(step.nextStep("blocked")) // no transition → nil (terminal)
    }

    func testStepTerminalWhenNoTransitions() {
        let step = Step(name: "end", kind: .code, transitions: [:])
        XCTAssertNil(step.nextStep("done"))
    }

    // MARK: - Procedure

    func testProcedureDefaults() throws {
        let proc = try Procedure(
            name: "test_proc",
            steps: [
                Step(name: "verify", kind: .judgment, transitions: ["not_refuted": "approved"]),
                Step(name: "approved", kind: .code, transitions: [:]),
            ]
        )
        XCTAssertEqual(proc.name, "test_proc")
        XCTAssertEqual(proc.initialStep, "verify") // defaults to first step
        XCTAssertEqual(proc.maxRounds, 10)
        XCTAssertEqual(proc.stallThreshold, 2)
    }

    func testProcedureInitialStepOverride() throws {
        let proc = try Procedure(
            name: "proc",
            steps: [
                Step(name: "first", kind: .code),
                Step(name: "second", kind: .judgment),
            ],
            initialStep: "second"
        )
        XCTAssertEqual(proc.initialStep, "second")
    }

    func testProcedureInitialStepNotFound() {
        XCTAssertThrowsError(try Procedure(
            name: "bad",
            steps: [Step(name: "exists", kind: .code)],
            initialStep: "nonexistent"
        )) { error in
            guard case ProcedureError.initialStepNotFound(let name) = error else {
                return XCTFail("expected initialStepNotFound, got \(error)")
            }
            XCTAssertEqual(name, "nonexistent")
        }
    }

    func testProcedureInvalidTransitionThrows() {
        XCTAssertThrowsError(try Procedure(
            name: "bad_transition",
            steps: [
                Step(name: "verify", kind: .judgment,
                     transitions: ["not_refuted": "ghost_step", "refuted": "end"]),
                Step(name: "end", kind: .code, transitions: [:]),
            ]
        )) { error in
            guard case ProcedureError.invalidTransition(let from, let to) = error else {
                return XCTFail("expected invalidTransition, got \(error)")
            }
            XCTAssertEqual(from, "verify")
            XCTAssertEqual(to, "ghost_step")
        }
    }

    func testProcedureSelfLoopTransitionValid() throws {
        // A transition that loops back to its own step is valid.
        let proc = try Procedure(
            name: "self_loop",
            steps: [
                Step(name: "verify", kind: .judgment, transitions: ["refuted": "verify"]),
            ]
        )
        XCTAssertEqual(proc.transition(from: "verify", outcome: "refuted"), "verify")
    }

    func testProcedureGetStep() throws {
        let proc = try Procedure(
            name: "proc",
            steps: [Step(name: "s1", kind: .code)]
        )
        let step = try proc.getStep("s1")
        XCTAssertEqual(step.name, "s1")
    }

    func testProcedureGetStepNotFound() throws {
        let proc = try Procedure(
            name: "proc",
            steps: [Step(name: "s1", kind: .code)]
        )
        XCTAssertThrowsError(try proc.getStep("missing")) { error in
            guard case ProcedureError.stepNotFound(let name) = error else {
                return XCTFail("expected stepNotFound")
            }
            XCTAssertEqual(name, "missing")
        }
    }

    func testProcedureTransition() throws {
        let proc = try Procedure(
            name: "proc",
            steps: [
                Step(name: "verify", kind: .judgment, transitions: [
                    "refuted": "rejected",
                    "not_refuted": "approved",
                ]),
                Step(name: "approved", kind: .code, transitions: [:]),
                Step(name: "rejected", kind: .code, transitions: [:]),
            ]
        )
        XCTAssertEqual(proc.transition(from: "verify", outcome: "refuted"), "rejected")
        XCTAssertEqual(proc.transition(from: "verify", outcome: "not_refuted"), "approved")
        // Self-loop when no transition
        XCTAssertEqual(proc.transition(from: "verify", outcome: "blocked"), "verify")
    }

    func testProcedureIsTerminal() throws {
        let proc = try Procedure(
            name: "proc",
            steps: [
                Step(name: "verify", kind: .judgment, transitions: ["not_refuted": "approved"]),
                Step(name: "approved", kind: .code, transitions: [:]),
            ]
        )
        XCTAssertFalse(proc.isTerminal("verify"))
        XCTAssertTrue(proc.isTerminal("approved"))
        XCTAssertTrue(proc.isTerminal("unknown"))
    }

    func testProcedureStepNames() throws {
        let proc = try Procedure(
            name: "proc",
            steps: [
                Step(name: "first", kind: .code),
                Step(name: "second", kind: .judgment),
            ]
        )
        XCTAssertEqual(proc.stepNames(), ["first", "second"])
    }

    func testProcedureToDict() throws {
        let proc = try Procedure(
            name: "test",
            steps: [
                Step(name: "verify", kind: .judgment, statutes: ["hate_speech"], transitions: ["not_refuted": "end"]),
                Step(name: "end", kind: .code, transitions: [:]),
            ],
            maxRounds: 5,
            stallThreshold: 3
        )
        let d = proc.toDict()
        XCTAssertEqual(d["name"] as? String, "test")
        XCTAssertEqual(d["max_rounds"] as? Int, 5)
        XCTAssertEqual(d["stall_threshold"] as? Int, 3)
        let steps = d["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0]["name"] as? String, "verify")
    }

    // MARK: - StallDetector

    func testStallDetectorDefaults() {
        let detector = StallDetector()
        XCTAssertEqual(detector.threshold, 2)
        XCTAssertNil(detector.lastFingerprint)
        XCTAssertEqual(detector.count, 0)
    }

    func testStallDetectorEmptyFpNoOp() {
        var detector = StallDetector(threshold: 2)
        XCTAssertFalse(detector.check(""))
        XCTAssertNil(detector.lastFingerprint)
        XCTAssertEqual(detector.count, 0)
    }

    func testStallDetectorTriggers() {
        var detector = StallDetector(threshold: 2)
        XCTAssertFalse(detector.check("abc123"))
        XCTAssertEqual(detector.count, 1)
        XCTAssertTrue(detector.check("abc123"))
        XCTAssertEqual(detector.count, 2)
    }

    func testStallDetectorResetsOnDifferentFp() {
        var detector = StallDetector(threshold: 3)
        _ = detector.check("abc") // count = 1
        _ = detector.check("abc") // count = 2
        _ = detector.check("def") // count = 1 (reset)
        XCTAssertEqual(detector.lastFingerprint, "def")
        XCTAssertEqual(detector.count, 1)
    }

    func testStallDetectorReset() {
        var detector = StallDetector(threshold: 2)
        _ = detector.check("abc")
        detector.reset()
        XCTAssertNil(detector.lastFingerprint)
        XCTAssertEqual(detector.count, 0)
    }
}
