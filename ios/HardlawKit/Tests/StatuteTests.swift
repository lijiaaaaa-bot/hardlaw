import XCTest
@testable import HardlawKit

final class StatuteTests: XCTestCase {

    // MARK: - ViolationType

    func testViolationTypeDefaultDescription() {
        let v = ViolationType(name: "hate_speech", severity: .critical)
        XCTAssertEqual(v.description, "")
    }

    func testViolationTypeFullInit() {
        let v = ViolationType(name: "pii_leak", severity: .high, description: "PII detected")
        XCTAssertEqual(v.name, "pii_leak")
        XCTAssertEqual(v.severity, .high)
        XCTAssertEqual(v.description, "PII detected")
    }

    // MARK: - EscalationRule

    func testEscalationRuleDefaults() {
        let rule = EscalationRule()
        XCTAssertEqual(rule.maxViolations, 3)
        XCTAssertEqual(rule.action, .block)
        XCTAssertNil(rule.escalateTo)
    }

    // MARK: - Statute

    func testStatuteDefaults() {
        let s = Statute(name: "test_statute")
        XCTAssertEqual(s.name, "test_statute")
        XCTAssertEqual(s.description, "")
        XCTAssertEqual(s.threshold, [:])
        XCTAssertEqual(s.requiredEvidence, [])
        XCTAssertEqual(s.violations, [])
        XCTAssertEqual(s.escalation.maxViolations, 3)
        XCTAssertTrue(s.defaultToReject)
        XCTAssertTrue(s.blocking)
    }

    func testStatuteToDict() {
        let v = ViolationType(name: "violation1", severity: .high, description: "test violation")
        let rule = EscalationRule(maxViolations: 5, action: .flag, escalateTo: "escalated_statute")
        let s = Statute(
            name: "statute1",
            description: "A test statute",
            threshold: ["confidence_min": .string("medium")],
            requiredEvidence: [EvidenceRequirement(evidence: "ocr_frame")],
            violations: [v],
            escalation: rule,
            defaultToReject: true,
            blocking: true
        )
        let d = s.toDict()
        XCTAssertEqual(d["name"] as? String, "statute1")
        XCTAssertEqual(d["description"] as? String, "A test statute")
        XCTAssertEqual(s.requiredEvidence.map(\.evidence), ["ocr_frame"])
        XCTAssertEqual(d["default_to_reject"] as? Bool, true)

        let violations = d["violations"] as? [[String: Any]] ?? []
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations[0]["name"] as? String, "violation1")
        XCTAssertEqual(violations[0]["severity"] as? String, "high")

        let esc = d["escalation"] as? [String: Any] ?? [:]
        XCTAssertEqual(esc["max_violations"] as? Int, 5)
        XCTAssertEqual(esc["action"] as? String, "flag")
        XCTAssertEqual(esc["escalate_to"] as? String, "escalated_statute")
    }

    func testStatuteToDictNilEscalateTo() {
        let rule = EscalationRule(maxViolations: 3, action: .block)
        let s = Statute(name: "s1", escalation: rule)
        let d = s.toDict()
        let esc = d["escalation"] as? [String: Any] ?? [:]
        // When escalateTo is nil, key should be absent or nil
        XCTAssertNil(esc["escalate_to"] as? String)
    }

    func testStatuteFromDictMinimal() {
        let data: [String: Any] = ["name": "minimal"]
        let s = Statute.fromDict(data)
        XCTAssertEqual(s.name, "minimal")
        XCTAssertEqual(s.description, "")
        XCTAssertEqual(s.violations, [])
        XCTAssertEqual(s.requiredEvidence, [])
        XCTAssertEqual(s.escalation.maxViolations, 3)
        XCTAssertTrue(s.defaultToReject)
    }

    func testStatuteFromDictFull() {
        let data: [String: Any] = [
            "name": "full_statute",
            "description": "Fully specified",
            "threshold": ["confidence_min": "high"],
            "required_evidence": ["ocr_frame", "vision_analysis"],
            "violations": [
                ["name": "hate_speech", "severity": "critical", "description": "Hate speech detected"],
            ],
            "escalation": [
                "max_violations": 10,
                "action": "pause",
            ],
            "default_to_reject": false,
            "blocking": false,
        ]
        let s = Statute.fromDict(data)
        XCTAssertEqual(s.name, "full_statute")
        XCTAssertEqual(s.threshold["confidence_min"], .string("high"))
        XCTAssertEqual(s.requiredEvidence.map(\.evidence), ["ocr_frame", "vision_analysis"])
        XCTAssertEqual(s.violations.count, 1)
        XCTAssertEqual(s.violations[0].name, "hate_speech")
        XCTAssertEqual(s.violations[0].severity, .critical)
        XCTAssertEqual(s.escalation.maxViolations, 10)
        XCTAssertEqual(s.escalation.action, .pause)
        XCTAssertFalse(s.defaultToReject)
        XCTAssertFalse(s.blocking)
    }

    func testStatuteCodableRoundTrip() throws {
        let v = ViolationType(name: "v1", severity: .medium, description: "desc")
        let s = Statute(
            name: "roundtrip",
            description: "Round-trip test",
            threshold: ["key": .number(0.5)],
            requiredEvidence: [EvidenceRequirement(evidence: "source1")],
            violations: [v],
            escalation: EscalationRule(maxViolations: 7, action: .notify),
            defaultToReject: false,
            blocking: false
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Statute.self, from: data)
        XCTAssertEqual(decoded.name, s.name)
        XCTAssertEqual(decoded.description, s.description)
        XCTAssertEqual(decoded.requiredEvidence, s.requiredEvidence)
        XCTAssertEqual(decoded.violations.count, 1)
        XCTAssertEqual(decoded.violations[0].name, "v1")
        XCTAssertEqual(decoded.violations[0].severity, .medium)
        XCTAssertEqual(decoded.escalation.maxViolations, 7)
        XCTAssertEqual(decoded.escalation.action, .notify)
        XCTAssertEqual(decoded.defaultToReject, false)
        XCTAssertEqual(decoded.blocking, false)
    }

    func testStatuteDecodeDefaultsMissingKeys() throws {
        let json = #"{"name": "bare"}"#
        let data = json.data(using: .utf8)!
        let s = try JSONDecoder().decode(Statute.self, from: data)
        XCTAssertEqual(s.name, "bare")
        XCTAssertEqual(s.description, "")
        XCTAssertEqual(s.requiredEvidence, [])
        XCTAssertTrue(s.defaultToReject) // default when missing
        XCTAssertTrue(s.blocking) // default when missing
    }

    // MARK: - StatuteBook

    func testStatuteBookAddAndGet() {
        var book = StatuteBook()
        let s = Statute(name: "s1")
        book.add(s)
        XCTAssertEqual(book.count, 1)
        XCTAssertNotNil(book.get("s1"))
        XCTAssertNil(book.get("nonexistent"))
    }

    func testStatuteBookReplaceOnAdd() {
        var book = StatuteBook()
        book.add(Statute(name: "s1", description: "first"))
        book.add(Statute(name: "s1", description: "second"))
        XCTAssertEqual(book.get("s1")?.description, "second")
        XCTAssertEqual(book.count, 1)
    }

    func testStatuteBookGetAllSkipsUnknown() {
        var book = StatuteBook()
        book.add(Statute(name: "a"))
        book.add(Statute(name: "b"))
        let result = book.getAll(["a", "c", "b"])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.name), ["a", "b"])
    }

    func testStatuteBookListNames() {
        var book = StatuteBook()
        book.add(Statute(name: "z"))
        book.add(Statute(name: "a"))
        // List names reflects internal dictionary order
        let names = book.listNames()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("z"))
        XCTAssertTrue(names.contains("a"))
    }

    func testStatuteBookContains() {
        var book = StatuteBook()
        book.add(Statute(name: "found"))
        XCTAssertTrue(book.contains("found"))
        XCTAssertFalse(book.contains("missing"))
    }

    func testStatuteBookToDict() {
        var book = StatuteBook()
        book.add(Statute(name: "s1", description: "statute 1"))
        book.add(Statute(name: "s2", description: "statute 2"))
        let d = book.toDict()
        let statutes = d["statutes"] as? [[String: Any]] ?? []
        XCTAssertEqual(statutes.count, 2)
    }

    func testStatuteBookFromDict() {
        let data: [String: Any] = [
            "statutes": [
                ["name": "s1", "description": "first"],
                ["name": "s2", "description": "second"],
            ]
        ]
        let book = StatuteBook.fromDict(data)
        XCTAssertEqual(book.count, 2)
        XCTAssertEqual(book.get("s1")?.description, "first")
    }

    func testStatuteBookInitWithArray() {
        let statutes = [Statute(name: "a"), Statute(name: "b")]
        let book = StatuteBook(statutes: statutes)
        XCTAssertEqual(book.count, 2)
    }

    // MARK: - Severity

    func testSeverityAllCases() {
        XCTAssertEqual(Severity.allCases, [.critical, .high, .medium, .low])
    }

    func testSeverityCodable() throws {
        let s = EscalationRule(action: .notify)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(EscalationRule.self, from: data)
        XCTAssertEqual(decoded.action, .notify)
    }
}
