import Foundation

// MARK: - StepKind

/// The kind of a procedural step.
/// Mirrors Python `hardlaw.procedure.StepKind`.
public enum StepKind: String, Codable, Sendable {
    /// Deterministic code execution (handler runs synchronously).
    case code
    /// LLM judgment point (invokes LLM, parses verdict, enforces evidence).
    case judgment
}

// MARK: - Step

/// A step in the procedure state machine.
/// Mirrors Python `hardlaw.procedure.Step`.
public struct Step: Sendable {
    /// Step identifier.
    public var name: String
    /// Whether this is a CODE or JUDGMENT step.
    public var kind: StepKind
    /// Deterministic handler (CODE steps only). Excluded from serialization.
    public var handler: (@Sendable (inout CaseContext) -> Void)?
    /// Statute names to apply at this judgment point (JUDGMENT steps only).
    public var statutes: [String]?
    /// Outcome → next step name transitions.
    public var transitions: [String: String]

    public init(
        name: String,
        kind: StepKind,
        handler: (@Sendable (inout CaseContext) -> Void)? = nil,
        statutes: [String]? = nil,
        transitions: [String: String] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.handler = handler
        self.statutes = statutes
        self.transitions = transitions
    }

    /// Return the next step name for an outcome, or nil if terminal.
    /// Mirrors Python `Step.next_step`.
    public func nextStep(_ outcome: String) -> String? {
        transitions[outcome]
    }
}

// MARK: - Codable (Step, handler excluded)

extension Step: Codable {
    enum CodingKeys: String, CodingKey {
        case name, kind, statutes, transitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(StepKind.self, forKey: .kind)
        statutes = try container.decodeIfPresent([String].self, forKey: .statutes)
        transitions = try container.decodeIfPresent([String: String].self, forKey: .transitions) ?? [:]
        handler = nil // handlers are not serializable
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(statutes, forKey: .statutes)
        if !transitions.isEmpty {
            try container.encode(transitions, forKey: .transitions)
        }
    }
}

// MARK: - CaseContext

/// Mutable state accumulating through the procedure.
/// Mirrors Python `hardlaw.procedure.CaseContext`.
public struct CaseContext: Sendable {
    /// Unique case identifier.
    public var caseId: String
    /// Case data — the "case file" being judged.
    public var data: [String: JSONValue]
    /// Accumulated verdicts from judgment steps.
    public var findings: [Verdict]
    /// Ordered history of step names visited.
    public var stepHistory: [String]
    /// Gap fingerprints collected for stall detection.
    public var gapFingerprints: [String]
    /// Current round count.
    public var roundCount: Int
    /// Arbitrary metadata (handlers can set actions here).
    public var metadata: [String: JSONValue]

    public init(
        caseId: String,
        data: [String: JSONValue] = [:],
        findings: [Verdict] = [],
        stepHistory: [String] = [],
        gapFingerprints: [String] = [],
        roundCount: Int = 0,
        metadata: [String: JSONValue] = [:]
    ) {
        self.caseId = caseId
        self.data = data
        self.findings = findings
        self.stepHistory = stepHistory
        self.gapFingerprints = gapFingerprints
        self.roundCount = roundCount
        self.metadata = metadata
    }
}

// MARK: - StallDetector

/// Detects repeated identical gap fingerprints.
/// When the same fingerprint appears consecutively threshold times, the case stalls.
/// Mirrors Python `hardlaw.procedure.StallDetector`.
public struct StallDetector: Sendable {
    /// Number of consecutive identical fingerprints to trigger.
    public var threshold: Int
    /// The last seen fingerprint.
    public var lastFingerprint: String?
    /// Consecutive count of the last fingerprint.
    public var count: Int

    public init(threshold: Int = 2) {
        self.threshold = threshold
        self.lastFingerprint = nil
        self.count = 0
    }

    /// Check if this fingerprint triggers a stall.
    /// Empty fingerprints are ignored and do NOT mutate state.
    /// Returns true when the same non-empty fp appears consecutively threshold times.
    /// Mirrors Python `StallDetector.check`.
    public mutating func check(_ fp: String) -> Bool {
        if fp.isEmpty { return false }
        if fp == lastFingerprint {
            count += 1
        } else {
            lastFingerprint = fp
            count = 1
        }
        return count >= threshold
    }

    /// Reset the detector state.
    public mutating func reset() {
        lastFingerprint = nil
        count = 0
    }
}

// MARK: - Procedure

/// The complete procedure — an ordered state machine of Steps.
/// Mirrors Python `hardlaw.procedure.Procedure`.
public struct Procedure: Sendable {
    /// Human-readable name for this procedure.
    public var name: String
    /// Ordered list of steps.
    public var steps: [Step]
    /// Which step to start at (defaults to first step).
    public var initialStep: String
    /// Maximum rounds before forced termination.
    public var maxRounds: Int
    /// Stall detection threshold.
    public var stallThreshold: Int
    /// Fast lookup: step name → Step.
    private var stepMap: [String: Step]

    public init(
        name: String,
        steps: [Step],
        initialStep: String? = nil,
        maxRounds: Int = 10,
        stallThreshold: Int = 2
    ) throws {
        self.name = name
        self.steps = steps
        self.initialStep = initialStep ?? steps.first?.name ?? ""
        self.maxRounds = maxRounds
        self.stallThreshold = stallThreshold

        // Build lookup map
        var map: [String: Step] = [:]
        for step in steps {
            map[step.name] = step
        }
        self.stepMap = map

        // Validate initial step
        guard map[self.initialStep] != nil else {
            throw ProcedureError.initialStepNotFound(self.initialStep)
        }
    }

    /// Look up a step by name. Throws if not found.
    /// Mirrors Python `Procedure.get_step` (raises KeyError).
    public func getStep(_ name: String) throws -> Step {
        guard let step = stepMap[name] else {
            throw ProcedureError.stepNotFound(name)
        }
        return step
    }

    /// Transition from a step given an outcome. Returns the next step name,
    /// or the current step name if no transition exists.
    /// Mirrors Python `Procedure.transition`.
    public func transition(from current: String, outcome: String) -> String {
        guard let step = stepMap[current] else { return current }
        return step.transitions[outcome] ?? current
    }

    /// Whether a step has no transitions (is terminal).
    public func isTerminal(_ stepName: String) -> Bool {
        guard let step = stepMap[stepName] else { return true }
        return step.transitions.isEmpty
    }

    /// All step names in order.
    public func stepNames() -> [String] {
        steps.map(\.name)
    }

    /// Serialize to dict (handlers excluded — mirrors Python `to_dict`).
    public func toDict() -> [String: Any] {
        [
            "name": name,
            "initial_step": initialStep,
            "max_rounds": maxRounds,
            "stall_threshold": stallThreshold,
            "steps": steps.map { step in
                var d: [String: Any] = [
                    "name": step.name,
                    "kind": step.kind.rawValue,
                    "transitions": step.transitions,
                ]
                if let statutes = step.statutes {
                    d["statutes"] = statutes
                }
                return d
            },
        ]
    }
}

// MARK: - Errors

public enum ProcedureError: Error, Sendable {
    case initialStepNotFound(String)
    case stepNotFound(String)
}
