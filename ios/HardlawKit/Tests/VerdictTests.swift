import XCTest
@testable import HardlawKit

final class VerdictTests: XCTestCase {

    // MARK: - Confidence

    func testConfidenceParse() {
        XCTAssertEqual(Confidence.parse("high"), .high)
        XCTAssertEqual(Confidence.parse("HIGH"), .high)
        XCTAssertEqual(Confidence.parse("High"), .high)
        XCTAssertEqual(Confidence.parse("medium"), .medium)
        XCTAssertEqual(Confidence.parse("low"), .low)
        XCTAssertEqual(Confidence.parse("unknown"), .unknown)
        XCTAssertEqual(Confidence.parse("garbage"), .unknown)
        XCTAssertEqual(Confidence.parse(""), .unknown)
    }

    // MARK: - Finding

    func testFindingDefaults() {
        let f = Finding()
        XCTAssertTrue(f.isEmpty)
    }

    func testFindingIsEmpty() {
        XCTAssertTrue(Finding(kind: "", location: "", detail: "").isEmpty)
        XCTAssertTrue(Finding(kind: "  ", location: "", detail: "").isEmpty)
        XCTAssertFalse(Finding(kind: "bug", location: "", detail: "").isEmpty)
        XCTAssertFalse(Finding(kind: "", location: "file:1", detail: "").isEmpty)
        XCTAssertFalse(Finding(kind: "", location: "", detail: "detail").isEmpty)
    }

    // MARK: - Verdict

    func testVerdictFailClosedDefaults() {
        let v = Verdict()
        XCTAssertEqual(v.finding, "")
        XCTAssertTrue(v.refuted) // fail-closed
        XCTAssertEqual(v.confidence, .medium)
        XCTAssertFalse(v.blocking)
        XCTAssertEqual(v.blockingKind, "none")
        XCTAssertEqual(v.evidenceRefs, [])
        XCTAssertEqual(v.findings, [])
        XCTAssertEqual(v.reasoning, "")
        XCTAssertNil(v.fallbackNote)
    }

    func testVerdictIsDecisive() {
        let decisive = Verdict(finding: "gap", refuted: true, confidence: .high, blocking: false)
        XCTAssertTrue(decisive.isDecisive)

        let notDecisive1 = Verdict(finding: "gap", refuted: true, confidence: .medium, blocking: false)
        XCTAssertFalse(notDecisive1.isDecisive)

        let notDecisive2 = Verdict(finding: "gap", refuted: false, confidence: .high, blocking: false)
        XCTAssertFalse(notDecisive2.isDecisive)

        let notDecisive3 = Verdict(finding: "gap", refuted: true, confidence: .high, blocking: true)
        XCTAssertFalse(notDecisive3.isDecisive)
    }

    func testVerdictToDict() {
        let v = Verdict(
            finding: "hate_speech",
            refuted: true,
            confidence: .high,
            blocking: true,
            blockingKind: BlockingKind.contradiction,
            evidenceRefs: [EvidenceRef(source: "ocr", location: "0", snippet: "bad word")],
            findings: [Finding(kind: "gap", location: "ocr:5", detail: "found banned term")],
            reasoning: "Banned term detected"
        )
        let d = v.toDict()
        XCTAssertEqual(d["finding"] as? String, "hate_speech")
        XCTAssertEqual(d["refuted"] as? Bool, true)
        XCTAssertEqual(d["confidence"] as? String, "high")
        // blocking key holds the string kind, not the boolean
        XCTAssertEqual(d["blocking"] as? String, BlockingKind.contradiction)
    }

    // MARK: - Verdict Codable (blocking field handling)

    func testDecodeBlockingStringKindContradiction() throws {
        let json = #"{"finding":"test","refuted":true,"confidence":"high","blocking":"contradiction","evidence_refs":[],"findings":[],"reasoning":"r"}"#
        let v = try JSONDecoder().decode(Verdict.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(v.blocking)
        XCTAssertEqual(v.blockingKind, "contradiction")
    }

    func testDecodeBlockingStringKindUnverifiable() throws {
        let json = #"{"finding":"test","refuted":true,"confidence":"high","blocking":"unverifiable","evidence_refs":[],"findings":[],"reasoning":"r"}"#
        let v = try JSONDecoder().decode(Verdict.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(v.blocking)
        XCTAssertEqual(v.blockingKind, "unverifiable")
    }

    func testDecodeBlockingStringKindNone() throws {
        let json = #"{"finding":"test","refuted":true,"confidence":"high","blocking":"none","evidence_refs":[],"findings":[],"reasoning":"r"}"#
        let v = try JSONDecoder().decode(Verdict.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(v.blocking)
        XCTAssertEqual(v.blockingKind, "none")
    }

    func testDecodeBlockingUnknownKindNormalized() throws {
        // Unknown blocking kind → normalized to "none" (mirrors Python)
        let json = #"{"finding":"test","refuted":true,"confidence":"medium","blocking":"weird_value","evidence_refs":[],"findings":[],"reasoning":"r"}"#
        let v = try JSONDecoder().decode(Verdict.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(v.blocking)
        XCTAssertEqual(v.blockingKind, "none")
    }

    func testDecodeMinimalVerdict() throws {
        let json = #"{}"#
        let v = try JSONDecoder().decode(Verdict.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(v.finding, "")
        XCTAssertTrue(v.refuted) // fail-closed default
        XCTAssertEqual(v.confidence, .medium)
        XCTAssertFalse(v.blocking)
    }

    func testEncodeDecodeRoundTrip() throws {
        let v = Verdict(
            finding: "violation",
            refuted: true,
            confidence: .low,
            blocking: true,
            blockingKind: BlockingKind.contradiction,
            evidenceRefs: [EvidenceRef(source: "s", snippet: "text")],
            findings: [Finding(kind: "bug", location: "file:1", detail: "issue")],
            reasoning: "because",
            fallbackNote: "test fallback"
        )
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(Verdict.self, from: data)
        XCTAssertEqual(decoded.finding, v.finding)
        XCTAssertEqual(decoded.refuted, v.refuted)
        XCTAssertEqual(decoded.confidence, v.confidence)
        XCTAssertEqual(decoded.blocking, v.blocking)
        XCTAssertEqual(decoded.blockingKind, v.blockingKind)
        XCTAssertEqual(decoded.evidenceRefs.count, 1)
        XCTAssertEqual(decoded.findings.count, 1)
        XCTAssertEqual(decoded.reasoning, v.reasoning)
        XCTAssertEqual(decoded.fallbackNote, v.fallbackNote)
    }

    // MARK: - VerdictParser

    func testParseJSONVerdict() {
        let raw = #"{"finding":"hate_speech","refuted":true,"confidence":"high","blocking":"contradiction","evidence_refs":[{"source":"ocr","location":"5","snippet":"bad","kind":"text"}],"reasoning":"test","findings":[{"kind":"gap","location":"ocr:5","detail":"banned term"}]}"#
        let v = VerdictParser.parse(raw)
        XCTAssertEqual(v.finding, "hate_speech")
        XCTAssertTrue(v.refuted)
        XCTAssertEqual(v.confidence, .high)
        XCTAssertTrue(v.blocking)
        XCTAssertEqual(v.blockingKind, "contradiction")
        XCTAssertEqual(v.evidenceRefs.count, 1)
        XCTAssertEqual(v.evidenceRefs[0].source, "ocr")
        XCTAssertEqual(v.findings.count, 1)
    }

    func testParseFencedJSON() {
        let raw = """
        You are a judge.

        ```json
        {"finding":"none","refuted":false,"confidence":"high","blocking":"none","evidence_refs":[],"reasoning":"all clean","findings":[]}
        ```

        Let me know if you need anything else.
        """
        let v = VerdictParser.parse(raw)
        XCTAssertEqual(v.finding, "none")
        XCTAssertFalse(v.refuted)
        XCTAssertEqual(v.confidence, .high)
    }

    func testParseTerminalTokenRefuted() {
        let v = VerdictParser.parse("Refuted")
        XCTAssertTrue(v.refuted)
        XCTAssertEqual(v.finding, "none")
        XCTAssertNotNil(v.fallbackNote)
        XCTAssertTrue(v.fallbackNote!.contains("terminal token"))
    }

    func testParseTerminalTokenNotRefuted() {
        let v = VerdictParser.parse("Not Refuted")
        XCTAssertFalse(v.refuted)
        XCTAssertEqual(v.finding, "unknown")
        XCTAssertNotNil(v.fallbackNote)
    }

    func testParseTerminalTokenWithFences() {
        let raw = """
        ```
        Refuted
        ```
        """
        let v = VerdictParser.parse(raw)
        // The code fence lines are skipped, Refuted on its own line is found
        // But since it's inside code fences... the line starts with "Refuted" before ```
        // Our parser drops "```"-prefixed lines, so "Refuted" line is found
        XCTAssertTrue(v.refuted)
    }

    func testParseTerminalTokenWithTrailingPunctuation() {
        let v = VerdictParser.parse("Refuted.")
        XCTAssertTrue(v.refuted)
    }

    func testParseEmptyFallsBackToReject() {
        let v = VerdictParser.parse("")
        XCTAssertEqual(v.finding, "parse_failure")
        XCTAssertTrue(v.refuted)
        XCTAssertTrue(v.blocking)
        XCTAssertEqual(v.confidence, .unknown)
        XCTAssertNotNil(v.fallbackNote)
    }

    func testParseGarbageFallsBackToReject() {
        let v = VerdictParser.parse("This is just some random text with no JSON and no terminal token")
        XCTAssertEqual(v.finding, "parse_failure")
        XCTAssertTrue(v.refuted)
        XCTAssertTrue(v.blocking)
    }

    // MARK: - Fingerprint

    func testFingerprintEmptyFindings() {
        let fp = Fingerprint.compute(findings: [])
        XCTAssertEqual(fp, "")
    }

    func testFingerprintSingleFinding() {
        let findings = [Finding(kind: "bug", location: "file:1", detail: "null check missing")]
        let fp = Fingerprint.compute(findings: findings)
        XCTAssertEqual(fp.count, 16)
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit })
    }

    func testFingerprintDeterministic() {
        let findings = [
            Finding(kind: "gap", location: "a:1", detail: "missing x"),
            Finding(kind: "bug", location: "b:2", detail: "bad y"),
        ]
        let fp1 = Fingerprint.compute(findings: findings)
        let fp2 = Fingerprint.compute(findings: findings)
        XCTAssertEqual(fp1, fp2)
    }

    func testFingerprintOrderIndependent() {
        let findings1 = [
            Finding(kind: "gap", location: "a:1", detail: "first"),
            Finding(kind: "bug", location: "b:2", detail: "second"),
        ]
        let findings2 = [
            Finding(kind: "bug", location: "b:2", detail: "second"),
            Finding(kind: "gap", location: "a:1", detail: "first"),
        ]
        let fp1 = Fingerprint.compute(findings: findings1)
        let fp2 = Fingerprint.compute(findings: findings2)
        XCTAssertEqual(fp1, fp2)
    }

    func testFingerprintSkipsEmptyFindings() {
        let findings = [
            Finding(kind: "bug", location: "a:1", detail: "real"),
            Finding(kind: "", location: "", detail: ""), // empty, skipped
        ]
        let fp1 = Fingerprint.compute(findings: findings)
        let fp2 = Fingerprint.compute(findings: [Finding(kind: "bug", location: "a:1", detail: "real")])
        XCTAssertEqual(fp1, fp2)
    }
}
