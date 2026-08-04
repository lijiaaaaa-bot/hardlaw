import XCTest
@testable import HardlawKit

final class EvidenceTests: XCTestCase {

    // MARK: - EvidenceRef

    func testEvidenceRefDefaults() {
        let ref = EvidenceRef(source: "doc")
        XCTAssertEqual(ref.source, "doc")
        XCTAssertEqual(ref.location, "")
        XCTAssertEqual(ref.snippet, "")
        XCTAssertEqual(ref.kind, "text")
    }

    func testEvidenceRefIsEmpty() {
        let empty = EvidenceRef(source: "doc")
        XCTAssertTrue(empty.isEmpty)

        let nonEmpty = EvidenceRef(source: "doc", snippet: "actual text")
        XCTAssertFalse(nonEmpty.isEmpty)

        let whitespace = EvidenceRef(source: "doc", snippet: "   ")
        XCTAssertTrue(whitespace.isEmpty)
    }

    func testEvidenceRefToDict() {
        let ref = EvidenceRef(source: "ocr_frame", location: "line 5", snippet: "hello world", kind: "text")
        let d = ref.toDict()
        XCTAssertEqual(d["source"] as? String, "ocr_frame")
        XCTAssertEqual(d["location"] as? String, "line 5")
        XCTAssertEqual(d["snippet"] as? String, "hello world")
        XCTAssertEqual(d["kind"] as? String, "text")
    }

    // MARK: - EvidenceRule

    func testEvidenceRuleDefaults() {
        let rule = EvidenceRule()
        XCTAssertEqual(rule.minCitations, 1)
        XCTAssertTrue(rule.mustBeVerifiable)
        XCTAssertEqual(rule.maxClaimWithoutEvidence, 0)
    }

    func testValidateEmptyRefsWithMinCitations() {
        let rule = EvidenceRule(minCitations: 1)
        let (passed, reason) = rule.validate([])
        XCTAssertFalse(passed)
        XCTAssertTrue(reason.contains("No evidence citations"))
    }

    func testValidateMissingRequiredSource() {
        let rule = EvidenceRule(requiredSources: ["ocr_frame"], minCitations: 1)
        let ref = EvidenceRef(source: "other_source", snippet: "text")
        let (passed, reason) = rule.validate([ref])
        XCTAssertFalse(passed)
        XCTAssertTrue(reason.contains("Required source"))
    }

    func testValidateInsufficientCitations() {
        let rule = EvidenceRule(minCitations: 2)
        let ref = EvidenceRef(source: "s1", snippet: "text")
        let (passed, reason) = rule.validate([ref])
        XCTAssertFalse(passed)
        XCTAssertTrue(reason.contains("Insufficient"))
    }

    func testValidateEmptySnippetWithVerifiability() {
        let rule = EvidenceRule(requiredSources: [], minCitations: 1, mustBeVerifiable: true)
        let ref = EvidenceRef(source: "s1", snippet: "")
        let (passed, reason) = rule.validate([ref])
        XCTAssertFalse(passed)
        XCTAssertTrue(reason.contains("empty"))
    }

    func testValidatePassesWithValidEvidence() {
        let rule = EvidenceRule(requiredSources: ["ocr_frame"], minCitations: 1)
        let ref = EvidenceRef(source: "ocr_frame", snippet: "real text")
        let (passed, reason) = rule.validate([ref])
        XCTAssertTrue(passed)
        XCTAssertEqual(reason, "")
    }

    // MARK: - EvidencePacket

    func testEvidencePacketToPromptSection() {
        let packet = EvidencePacket(
            objective: "Audit content",
            artifacts: ["ocr_frame": "some text"],
            priorGaps: ["gap1"]
        )
        let section = packet.toPromptSection()
        XCTAssertTrue(section.contains("## OBJECTIVE"))
        XCTAssertTrue(section.contains("Audit content"))
        XCTAssertTrue(section.contains("## EVIDENCE"))
        XCTAssertTrue(section.contains("### ocr_frame"))
        XCTAssertTrue(section.contains("some text"))
        XCTAssertTrue(section.contains("## PRIOR GAPS"))
        XCTAssertTrue(section.contains("- gap1"))
    }

    func testEvidencePacketNoGaps() {
        let packet = EvidencePacket(objective: "test")
        let section = packet.toPromptSection()
        XCTAssertFalse(section.contains("## PRIOR GAPS"))
    }

    // MARK: - EvidenceValidator

    func testValidatorSubstringMatch() {
        var validator = EvidenceValidator()
        validator.addSource("ocr_frame", "The quick brown fox jumps over the lazy dog")
        let ref = EvidenceRef(source: "ocr_frame", snippet: "brown fox")
        XCTAssertTrue(validator.validate(ref))
    }

    func testValidatorUnknownSource() {
        let validator = EvidenceValidator()
        let ref = EvidenceRef(source: "unknown", snippet: "text")
        XCTAssertFalse(validator.validate(ref))
    }

    func testValidatorEmptySnippet() {
        var validator = EvidenceValidator()
        validator.addSource("ocr_frame", "content")
        let ref = EvidenceRef(source: "ocr_frame", snippet: "")
        XCTAssertFalse(validator.validate(ref))
    }

    func testValidatorNonMatchingSnippet() {
        var validator = EvidenceValidator()
        validator.addSource("ocr_frame", "hello world")
        let ref = EvidenceRef(source: "ocr_frame", snippet: "not present")
        XCTAssertFalse(validator.validate(ref))
    }

    func testValidatorExactSnippet() {
        var validator = EvidenceValidator()
        validator.addSource("ocr_frame", "exact match")
        let ref = EvidenceRef(source: "ocr_frame", snippet: "exact match")
        XCTAssertTrue(validator.validate(ref))
    }

    func testValidateAllPartialFailures() {
        var validator = EvidenceValidator()
        validator.addSource("src_a", "content A")
        let validRef = EvidenceRef(source: "src_a", snippet: "content A")
        let invalidRef = EvidenceRef(source: "unknown", snippet: "missing")
        let (allValid, failures) = validator.validateAll([validRef, invalidRef])
        XCTAssertFalse(allValid)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("unknown"))
    }

    func testValidateAllAllPass() {
        var validator = EvidenceValidator()
        validator.addSource("src_a", "hello")
        validator.addSource("src_b", "world")
        let refA = EvidenceRef(source: "src_a", snippet: "hello")
        let refB = EvidenceRef(source: "src_b", snippet: "world")
        let (allValid, failures) = validator.validateAll([refA, refB])
        XCTAssertTrue(allValid)
        XCTAssertEqual(failures.count, 0)
    }
}
