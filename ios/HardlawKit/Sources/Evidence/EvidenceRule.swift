import Foundation

// MARK: - EvidenceRule

/// Rules of evidence — what evidence is required for a judgment.
/// Mirrors Python `hardlaw.evidence.EvidenceRule`.
public struct EvidenceRule: Codable, Sendable {
    /// Sources that MUST be cited.
    public var requiredSources: [String]
    /// Minimum number of evidence citations required.
    public var minCitations: Int
    /// Whether every snippet must be non-blank.
    public var mustBeVerifiable: Bool
    /// Maximum claims without citing evidence.
    /// Note: declared but unused in validate() — mirrors Python dead code.
    public var maxClaimWithoutEvidence: Int

    public init(
        requiredSources: [String] = [],
        minCitations: Int = 1,
        mustBeVerifiable: Bool = true,
        maxClaimWithoutEvidence: Int = 0
    ) {
        self.requiredSources = requiredSources
        self.minCitations = minCitations
        self.mustBeVerifiable = mustBeVerifiable
        self.maxClaimWithoutEvidence = maxClaimWithoutEvidence
    }

    // Map Python JSON keys
    enum CodingKeys: String, CodingKey {
        case requiredSources = "required_sources"
        case minCitations = "min_citations"
        case mustBeVerifiable = "must_be_verifiable"
        case maxClaimWithoutEvidence = "max_claim_without_evidence"
    }

    /// Validate a list of evidence refs against these rules.
    /// Returns (passed: Bool, reason: String) — reason is empty when passed.
    /// Mirrors Python `EvidenceRule.validate`.
    public func validate(_ refs: [EvidenceRef]) -> (Bool, String) {
        // 1. Must have at least minCitations refs
        if minCitations > 0 && refs.isEmpty {
            return (false, "No evidence citations provided (required: \(minCitations))")
        }
        // 2. Every required source must be cited
        let citedSources = Set(refs.map(\.source))
        for required in requiredSources {
            if !citedSources.contains(required) {
                return (false, "Required source '\(required)' not cited")
            }
        }
        // 3. Count must meet minimum
        if refs.count < minCitations {
            return (false, "Insufficient citations: got \(refs.count), need \(minCitations)")
        }
        // 4. Every snippet must be non-blank if mustBeVerifiable
        if mustBeVerifiable {
            for ref in refs {
                if ref.isEmpty {
                    return (false, "Evidence ref from '\(ref.source)' has empty snippet")
                }
            }
        }
        return (true, "")
    }
}

// MARK: - EvidencePacket

/// A packet of evidence assembled for the judge.
/// Mirrors Python `hardlaw.evidence.EvidencePacket`.
public struct EvidencePacket: Sendable {
    public var objective: String
    public var artifacts: [String: String]
    public var priorGaps: [String]

    public init(objective: String, artifacts: [String: String] = [:], priorGaps: [String] = []) {
        self.objective = objective
        self.artifacts = artifacts
        self.priorGaps = priorGaps
    }

    /// Render as a markdown prompt section (mirrors Python `to_prompt_section`).
    public func toPromptSection() -> String {
        var lines: [String] = [
            "## OBJECTIVE",
            objective,
            "",
            "## EVIDENCE",
        ]
        for (kind, content) in artifacts {
            lines.append("### \(kind)")
            lines.append(content)
            lines.append("")
        }
        if !priorGaps.isEmpty {
            lines.append("## PRIOR GAPS")
            for gap in priorGaps {
                lines.append("- \(gap)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - EvidenceValidator

/// Validates that cited evidence snippets actually exist in the source material.
/// This is the anti-hallucination mechanism.
/// Mirrors Python `hardlaw.evidence.EvidenceValidator`.
public struct EvidenceValidator: Sendable {
    /// Source name → full content.
    private var sourceMaterial: [String: String] = [:]

    public init() {}

    /// Register a source document.
    public mutating func addSource(_ name: String, _ content: String) {
        sourceMaterial[name] = content
    }

    /// Validate a single ref: snippet must be a substring of the source.
    /// Mirrors Python `EvidenceValidator.validate`.
    public func validate(_ ref: EvidenceRef) -> Bool {
        guard let content = sourceMaterial[ref.source] else {
            return false // unknown source
        }
        let trimmedSnippet = ref.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSnippet.isEmpty { return false }
        return content.contains(trimmedSnippet)
    }

    /// Validate all refs. Returns (allValid: Bool, failures: [String]).
    /// Mirrors Python `EvidenceValidator.validate_all`.
    public func validateAll(_ refs: [EvidenceRef]) -> (Bool, [String]) {
        var failures: [String] = []
        for ref in refs {
            if !validate(ref) {
                failures.append(
                    "Evidence ref from '\(ref.source)' at '\(ref.location)' snippet '\(ref.snippet)' not found in source '\(ref.source)'"
                )
            }
        }
        return (failures.isEmpty, failures)
    }
}
