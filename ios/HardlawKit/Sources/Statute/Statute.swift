import Foundation

// MARK: - ViolationType

/// A kind of violation that can be found by an LLM judge.
/// Mirrors Python `hardlaw.statute.ViolationType`.
public struct ViolationType: Codable, Equatable, Sendable {
    /// Short identifier, e.g. "hate_speech", "missing_consent".
    public var name: String
    /// How serious the violation is.
    public var severity: Severity
    /// Human-readable definition for the judge.
    public var description: String

    public init(name: String, severity: Severity, description: String = "") {
        self.name = name
        self.severity = severity
        self.description = description
    }
}

// MARK: - Severity

/// Violation severity level.
/// Mirrors Python `Literal["critical", "high", "medium", "low"]`.
public enum Severity: String, Codable, Sendable, CaseIterable {
    case critical, high, medium, low
}

// MARK: - EscalationRule

/// What happens on repeated violations.
/// Mirrors Python `hardlaw.statute.EscalationRule`.
public struct EscalationRule: Codable, Equatable, Sendable {
    /// Escalate after N violations of the same type.
    public var maxViolations: Int
    /// What action to take on escalation.
    public var action: EscalationAction
    /// Name of escalated statute, if escalation changes the rule set.
    public var escalateTo: String?

    public init(maxViolations: Int = 3, action: EscalationAction = .block, escalateTo: String? = nil) {
        self.maxViolations = maxViolations
        self.action = action
        self.escalateTo = escalateTo
    }

    // Map Python JSON keys: "max_violations", "action", "escalate_to"
    enum CodingKeys: String, CodingKey {
        case maxViolations = "max_violations"
        case action
        case escalateTo = "escalate_to"
    }
}

/// Escalation actions matching Python `Literal["block", "flag", "notify", "pause"]`.
public enum EscalationAction: String, Codable, Sendable, CaseIterable {
    case block, flag, notify, pause
}

// MARK: - Evidence Requirement (举证责任分层)

/// Who holds the evidence — determines what happens when it's missing.
public enum EvidenceHolder: String, Codable, Sendable, CaseIterable {
    case worker     // 劳动者应自行举证
    case employer   // 用人单位掌握管理（《劳动争议调解仲裁法》第6条）
    case thirdParty // 行政机关/第三方，可申请调取
}

/// What to do when required evidence is missing.
public enum MissingEvidenceAction: String, Codable, Sendable, CaseIterable {
    case flag    // 提示缺口+举证责任提示，不阻断
    case prompt  // 要求补充或申请调取后继续
    case block   // 阻断，无重试（劳动者自行举证/LLM幻觉）
}

/// A structured evidence requirement replacing flat `[String]` lists.
/// Each entry specifies who should provide the evidence, what happens
/// when it's missing, and what alternatives exist.
public struct EvidenceRequirement: Codable, Equatable, Sendable {
    /// Evidence name, e.g. "工资表"
    public var evidence: String
    /// Who should provide this evidence
    public var holder: EvidenceHolder
    /// Action when evidence is missing
    public var onMissing: MissingEvidenceAction
    /// Legal basis for burden assignment
    public var burdenBasis: String?
    /// Alternative evidence that satisfies the same requirement
    public var alternatives: [EvidenceRequirement]
    /// Minimum number of alternatives (including primary) that must be satisfied
    public var minCount: Int

    public init(
        evidence: String,
        holder: EvidenceHolder = .worker,
        onMissing: MissingEvidenceAction = .block,
        burdenBasis: String? = nil,
        alternatives: [EvidenceRequirement] = [],
        minCount: Int = 1
    ) {
        self.evidence = evidence
        self.holder = holder
        self.onMissing = onMissing
        self.burdenBasis = burdenBasis
        self.alternatives = alternatives
        self.minCount = minCount
    }

    /// Convenience: create a simple worker-held requirement (backward compat).
    public init(_ evidence: String) {
        self.evidence = evidence
        self.holder = .worker
        self.onMissing = .block
        self.burdenBasis = nil
        self.alternatives = []
        self.minCount = 1
    }
}

// MARK: - Statute

/// A named hard rule encoding enforceable constraints on LLM agents.
/// A Statute is data, not code — it can be serialized to JSON/YAML.
/// Mirrors Python `hardlaw.statute.Statute`.
public struct Statute: Codable, Equatable, Sendable {
    /// Unique identifier, e.g. "hate_speech", "gdpr_consent".
    public var name: String
    /// Human-readable explanation of what this statute governs.
    public var description: String
    /// Multi-dimensional thresholds, e.g. {"confidence_min": "medium"}.
    public var threshold: [String: JSONValue]
    /// Evidence requirements (v2: structured with burden layering).
    /// Backward compatible: old `[String]` decodes to `.worker` + `.block`.
    public var requiredEvidence: [EvidenceRequirement]
    /// Kinds of violations this statute covers.
    public var violations: [ViolationType]
    /// What happens on repeated violations.
    public var escalation: EscalationRule
    /// When the judge is uncertain, default to rejecting.
    public var defaultToReject: Bool
    /// If True, a violation blocks the action entirely (no retry).
    public var blocking: Bool

    public init(
        name: String,
        description: String = "",
        threshold: [String: JSONValue] = [:],
        requiredEvidence: [EvidenceRequirement] = [],
        violations: [ViolationType] = [],
        escalation: EscalationRule = EscalationRule(),
        defaultToReject: Bool = true,
        blocking: Bool = true
    ) {
        self.name = name
        self.description = description
        self.threshold = threshold
        self.requiredEvidence = requiredEvidence
        self.violations = violations
        self.escalation = escalation
        self.defaultToReject = defaultToReject
        self.blocking = blocking
    }

    // Map Python JSON keys exactly (snake_case)
    enum CodingKeys: String, CodingKey {
        case name, description, threshold
        case requiredEvidence = "required_evidence"
        case violations, escalation
        case defaultToReject = "default_to_reject"
        case blocking
    }

    // Custom decoding with backward compatibility for old `[String]` format
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        threshold = try container.decodeIfPresent([String: JSONValue].self, forKey: .threshold) ?? [:]
        // Backward compat: try new [EvidenceRequirement] format first,
        // fall back to old [String] format (each string → .worker + .block)
        if let reqs = try? container.decode([EvidenceRequirement].self, forKey: .requiredEvidence) {
            requiredEvidence = reqs
        } else if let strings = try? container.decode([String].self, forKey: .requiredEvidence) {
            requiredEvidence = strings.map { EvidenceRequirement($0) }
        } else {
            requiredEvidence = []
        }
        violations = try container.decodeIfPresent([ViolationType].self, forKey: .violations) ?? []
        escalation = try container.decodeIfPresent(EscalationRule.self, forKey: .escalation) ?? EscalationRule()
        defaultToReject = try container.decodeIfPresent(Bool.self, forKey: .defaultToReject) ?? true
        blocking = try container.decodeIfPresent(Bool.self, forKey: .blocking) ?? true
    }

    /// Serialize to a plain dict (JSON-compatible, mirrors Python `to_dict`).
    public func toDict() -> [String: Any] {
        var result: [String: Any] = [
            "name": name,
            "description": description,
            "threshold": threshold.mapValues { $0 },
            "required_evidence": requiredEvidence.map { req in
                var d: [String: Any] = ["evidence": req.evidence, "holder": req.holder.rawValue, "on_missing": req.onMissing.rawValue]
                if let b = req.burdenBasis { d["burden_basis"] = b }
                if !req.alternatives.isEmpty { d["alternatives"] = req.alternatives.map { $0.evidence } }
                return d
            },
            "violations": violations.map { v in
                [
                    "name": v.name,
                    "severity": v.severity.rawValue,
                    "description": v.description,
                ]
            },
            "escalation": [
                "max_violations": escalation.maxViolations,
                "action": escalation.action.rawValue,
                "escalate_to": escalation.escalateTo as Any,
            ],
            "default_to_reject": defaultToReject,
            "blocking": blocking,
        ]
        // remove NSNull for escalate_to when nil (matches Python behavior)
        if escalation.escalateTo == nil {
            if var esc = result["escalation"] as? [String: Any] {
                esc.removeValue(forKey: "escalate_to")
                result["escalation"] = esc
            }
        }
        return result
    }

    /// Deserialize from a plain dict (mirrors Python `from_dict`).
    public static func fromDict(_ data: [String: Any]) -> Statute {
        let violations: [ViolationType] = (data["violations"] as? [[String: Any]] ?? []).map { v in
            ViolationType(
                name: v["name"] as? String ?? "",
                severity: Severity(rawValue: v["severity"] as? String ?? "low") ?? .low,
                description: v["description"] as? String ?? ""
            )
        }
        let escData = data["escalation"] as? [String: Any] ?? [:]
        let escalation = EscalationRule(
            maxViolations: escData["max_violations"] as? Int ?? 3,
            action: EscalationAction(rawValue: escData["action"] as? String ?? "block") ?? .block,
            escalateTo: escData["escalate_to"] as? String
        )
        return Statute(
            name: data["name"] as? String ?? "",
            description: data["description"] as? String ?? "",
            threshold: (data["threshold"] as? [String: Any] ?? [:]).mapValues { parseJSONPrimitive($0) },
            requiredEvidence: parseRequiredEvidence(data["required_evidence"]),
            violations: violations,
            escalation: escalation,
            defaultToReject: data["default_to_reject"] as? Bool ?? true,
            blocking: data["blocking"] as? Bool ?? true
        )
    }
}

/// Recursively convert Any → JSONValue for fromDict.
private func parseJSONPrimitive(_ value: Any) -> JSONValue {
    switch value {
    case let s as String: return .string(s)
    case let n as Double: return .number(n)
    case let n as Int: return .number(Double(n))
    case let b as Bool: return .bool(b)
    case let arr as [Any]: return .array(arr.map(parseJSONPrimitive))
    case let dict as [String: Any]: return .object(dict.mapValues(parseJSONPrimitive))
    case is NSNull: return .null
    default: return .string("\(value)")
    }
}

/// Parse required_evidence from dict — handles both old `[String]` and new structured format.
private func parseRequiredEvidence(_ value: Any?) -> [EvidenceRequirement] {
    // New format: array of dicts
    if let dicts = value as? [[String: Any]] {
        return dicts.compactMap { d in
            guard let evidence = d["evidence"] as? String else { return nil }
            return EvidenceRequirement(
                evidence: evidence,
                holder: EvidenceHolder(rawValue: d["holder"] as? String ?? "worker") ?? .worker,
                onMissing: MissingEvidenceAction(rawValue: d["on_missing"] as? String ?? "block") ?? .block,
                burdenBasis: d["burden_basis"] as? String,
                alternatives: (d["alternatives"] as? [String])?.map { EvidenceRequirement($0) } ?? [],
                minCount: d["min_count"] as? Int ?? 1
            )
        }
    }
    // Old format: array of strings
    if let strings = value as? [String] {
        return strings.map { EvidenceRequirement($0) }
    }
    return []
}
