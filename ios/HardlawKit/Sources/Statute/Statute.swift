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
    /// Evidence fields that MUST be cited in any verdict.
    public var requiredEvidence: [String]
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
        requiredEvidence: [String] = [],
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

    // Custom decoding to provide Python-identical defaults for missing keys
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        threshold = try container.decodeIfPresent([String: JSONValue].self, forKey: .threshold) ?? [:]
        requiredEvidence = try container.decodeIfPresent([String].self, forKey: .requiredEvidence) ?? []
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
            "required_evidence": requiredEvidence,
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
            requiredEvidence: data["required_evidence"] as? [String] ?? [],
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
