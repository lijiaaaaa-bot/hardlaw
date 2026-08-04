import Foundation
import HardlawKit

/// Pre-built statutes for content moderation.
/// Port of Python `examples/02_content_moderation.py`.
public enum ContentModerationStatutes {

    /// Hate speech statute.
    public static let hateSpeech = Statute(
        name: "hate_speech",
        description: "Content must not contain hate speech, harassment, or discriminatory language",
        requiredEvidence: ["content"],
        violations: [
            ViolationType(name: "hate_speech", severity: .critical, description: "Hate speech or discriminatory content detected"),
            ViolationType(name: "harassment", severity: .high, description: "Harassment or bullying detected"),
            ViolationType(name: "profanity", severity: .medium, description: "Profanity or offensive language"),
        ],
        escalation: EscalationRule(maxViolations: 3, action: .block),
        defaultToReject: true,
        blocking: true
    )

    /// PII/data protection statute.
    public static let dataProtection = Statute(
        name: "data_protection",
        description: "Content must not expose personally identifiable information (PII)",
        requiredEvidence: ["content"],
        violations: [
            ViolationType(name: "pii_leak", severity: .critical, description: "PII exposed (email, phone, credit card, SSN)"),
            ViolationType(name: "credential_leak", severity: .critical, description: "Credentials or secrets exposed"),
        ],
        escalation: EscalationRule(maxViolations: 1, action: .block),
        defaultToReject: true,
        blocking: true
    )

    /// Content quality statute.
    public static let contentQuality = Statute(
        name: "content_quality",
        description: "Content must meet minimum quality standards",
        requiredEvidence: [],
        violations: [
            ViolationType(name: "empty_content", severity: .low, description: "Content is empty or whitespace only"),
            ViolationType(name: "gibberish", severity: .low, description: "Content appears to be gibberish/nonsense"),
        ],
        escalation: EscalationRule(maxViolations: 5, action: .flag),
        defaultToReject: false,
        blocking: false
    )

    /// All statutes as an array.
    public static let all: [Statute] = [hateSpeech, dataProtection, contentQuality]

    /// Default statute book.
    public static let book = StatuteBook(statutes: all)

    /// Build the content moderation procedure.
    /// Mirrors `examples/02_content_moderation.py` structure.
    public static func makeAuditProcedure() throws -> Procedure {
        try Procedure(
            name: "content_audit",
            steps: [
                // Step 1: Pre-scan with CODE step for instant rule checks
                Step(
                    name: "prescan",
                    kind: .code,
                    handler: { ctx in
                        // Pre-scan: check for empty content
                        if let content = ctx.data["content"]?.stringValue,
                           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ctx.metadata["prescan_action"] = JSONValue.string("empty_detected")
                        } else {
                            ctx.metadata["prescan_action"] = JSONValue.string("proceed")
                        }
                    },
                    transitions: ["done": "verify"]
                ),
                // Step 2: Primary judgment — hate speech and data protection
                Step(
                    name: "verify",
                    kind: .judgment,
                    statutes: ["hate_speech", "data_protection"],
                    transitions: [
                        "blocked": "block_content",
                        "refuted": "severity_check",
                        "not_refuted": "approved",
                    ]
                ),
                // Step 3: Severity classification
                Step(
                    name: "severity_check",
                    kind: .code,
                    handler: { ctx in
                        // Determine severity from last verdict's findings
                        if let lastVerdict = ctx.findings.last {
                            let hasCritical = lastVerdict.findings.contains {
                                $0.kind == "critical" || $0.detail.contains("critical")
                            }
                            if hasCritical {
                                ctx.metadata["severity"] = JSONValue.string("critical")
                            } else {
                                ctx.metadata["severity"] = JSONValue.string("moderate")
                            }
                        }
                    },
                    transitions: ["done": "route_by_severity"]
                ),
                // Step 4: Route based on severity
                Step(
                    name: "route_by_severity",
                    kind: .code,
                    handler: { ctx in
                        let severity = ctx.metadata["severity"]?.stringValue ?? "moderate"
                        ctx.metadata["route"] = JSONValue.string(
                            severity == "critical" ? "critical" : "moderate"
                        )
                    },
                    transitions: [
                        "done": "warn_author", // moderate → warn
                    ]
                ),
                // Terminal steps
                Step(name: "approved", kind: .code, transitions: [:]),
                Step(
                    name: "block_content",
                    kind: .code,
                    handler: { ctx in
                        ctx.metadata["action"] = JSONValue.string("blocked")
                    },
                    transitions: [:]
                ),
                Step(
                    name: "warn_author",
                    kind: .code,
                    handler: { ctx in
                        ctx.metadata["action"] = JSONValue.string("warned")
                    },
                    transitions: [:]
                ),
            ],
            maxRounds: 5,
            stallThreshold: 3
        )
    }
}
