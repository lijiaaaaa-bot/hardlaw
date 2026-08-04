import Foundation

// MARK: - Blocking Constants

/// Blocking kind constants. Mirrors Python module-level constants.
public enum BlockingKind: Sendable {
    public static let none = "none"
    public static let contradiction = "contradiction"
    public static let unverifiable = "unverifiable"
}

// MARK: - Verdict

/// A structured judgment from the LLM judge.
/// Mirrors Python `hardlaw.verdict.Verdict`.
public struct Verdict: Equatable, Sendable {
    /// Violation type name found, or "none".
    public var finding: String
    /// Whether the content was refuted (fail-closed default: true).
    public var refuted: Bool
    /// Confidence level of the judgment.
    public var confidence: Confidence
    /// Whether this verdict blocks the action.
    public var blocking: Bool
    /// The blocking kind string ("none", "contradiction", "unverifiable").
    public var blockingKind: String
    /// Evidence citations backing this verdict.
    public var evidenceRefs: [EvidenceRef]
    /// Detailed findings (gaps, bugs, todos).
    public var findings: [Finding]
    /// Human-readable reasoning.
    public var reasoning: String
    /// Detailed markdown explanation (unused by Court, kept for parity).
    public var detailsMd: String
    /// Note explaining why fallback was used (nil = no fallback).
    public var fallbackNote: String?

    public init(
        finding: String = "",
        refuted: Bool = true,
        confidence: Confidence = .medium,
        blocking: Bool = false,
        blockingKind: String = BlockingKind.none,
        evidenceRefs: [EvidenceRef] = [],
        findings: [Finding] = [],
        reasoning: String = "",
        detailsMd: String = "",
        fallbackNote: String? = nil
    ) {
        self.finding = finding
        self.refuted = refuted
        self.confidence = confidence
        self.blocking = blocking
        self.blockingKind = blockingKind
        self.evidenceRefs = evidenceRefs
        self.findings = findings
        self.reasoning = reasoning
        self.detailsMd = detailsMd
        self.fallbackNote = fallbackNote
    }

    /// Returns true when refuted with high confidence and NOT blocking.
    /// Mirrors Python `Verdict.is_decisive`.
    public var isDecisive: Bool {
        refuted && confidence == .high && !blocking
    }

    /// Serialize to plain dict (mirrors Python `to_dict`).
    /// Note: does NOT include `detailsMd` or `fallbackNote` — matches Python behavior.
    public func toDict() -> [String: Any] {
        var result: [String: Any] = [
            "finding": finding,
            "refuted": refuted,
            "confidence": confidence.rawValue,
            "blocking": blockingKind, // wire format uses string kind
            "evidence_refs": evidenceRefs.map { $0.toDict() },
            "findings": findings.map { f in
                [
                    "kind": f.kind,
                    "location": f.location,
                    "detail": f.detail,
                ]
            },
            "reasoning": reasoning,
        ]
        return result
    }
}

// MARK: - Codable

extension Verdict: Codable {
    // Map Python JSON keys
    enum CodingKeys: String, CodingKey {
        case finding, refuted, confidence, blocking
        case evidenceRefs = "evidence_refs"
        case findings, reasoning
        case detailsMd = "details_md"
        case fallbackNote = "fallback_note"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finding = try container.decodeIfPresent(String.self, forKey: .finding) ?? ""
        refuted = try container.decodeIfPresent(Bool.self, forKey: .refuted) ?? true
        let confStr = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "medium"
        confidence = Confidence.parse(confStr)

        // Parse blocking: wire format is a string kind
        let rawBlocking = try container.decodeIfPresent(String.self, forKey: .blocking) ?? BlockingKind.none
        // Normalize unknown blocking kinds (mirrors Python behavior)
        switch rawBlocking {
        case BlockingKind.contradiction, BlockingKind.unverifiable:
            blockingKind = rawBlocking
            blocking = true
        case BlockingKind.none:
            blockingKind = BlockingKind.none
            blocking = false
        default:
            // Unknown value → normalize to "none" (Python does this)
            blockingKind = BlockingKind.none
            blocking = false
        }

        evidenceRefs = try container.decodeIfPresent([EvidenceRef].self, forKey: .evidenceRefs) ?? []
        findings = try container.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        detailsMd = try container.decodeIfPresent(String.self, forKey: .detailsMd) ?? ""
        fallbackNote = try container.decodeIfPresent(String.self, forKey: .fallbackNote)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(finding, forKey: .finding)
        try container.encode(refuted, forKey: .refuted)
        try container.encode(confidence.rawValue, forKey: .confidence)
        try container.encode(blockingKind, forKey: .blocking) // wire format uses string kind
        try container.encode(evidenceRefs, forKey: .evidenceRefs)
        try container.encode(findings, forKey: .findings)
        try container.encode(reasoning, forKey: .reasoning)
        if !detailsMd.isEmpty { try container.encode(detailsMd, forKey: .detailsMd) }
        if let note = fallbackNote { try container.encode(note, forKey: .fallbackNote) }
    }
}
