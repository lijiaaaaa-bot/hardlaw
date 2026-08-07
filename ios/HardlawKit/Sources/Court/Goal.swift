import Foundation

// MARK: - Goal-Driven Architecture

/// A goal represents a user's high-level intent.
/// The system plans, executes, and verifies until the goal is met.
///
/// Architecture from Grok Build /goal mode:
///   Plan → Execute → Verify → Reflect → Complete
///
/// Each step is a Court.hear() call with a specific Procedure.
/// Steps are visible to the user as a progress checklist.
public struct Goal: Sendable {
    public let id: UUID
    public let description: String
    public var steps: [GoalStep]
    public var status: GoalStatus
    public var createdAt: Date

    public init(description: String, steps: [GoalStep]) {
        self.id = UUID()
        self.description = description
        self.steps = steps
        self.status = .pending
        self.createdAt = .now
    }

    /// Progress: fraction 0..1
    public var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let done = Double(steps.filter { $0.status == .done || $0.status == .failed }.count)
        return done / Double(steps.count)
    }

    /// Whether all steps are complete.
    public var isComplete: Bool {
        steps.allSatisfy { $0.status == .done || $0.status == .failed }
    }
}

// MARK: - Goal Step

/// A single step in the goal-driven workflow.
/// Each step maps to a Procedure that Court.hear() executes.
public struct GoalStep: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let detail: String
    public let kind: GoalStepKind
    public var status: GoalStepStatus
    public var resultSummary: String

    public init(name: String, detail: String, kind: GoalStepKind) {
        self.id = UUID()
        self.name = name
        self.detail = detail
        self.kind = kind
        self.status = .pending
        self.resultSummary = ""
    }
}

public enum GoalStepKind: String, Sendable {
    case generateCatalog
    case verifyCitations
    case detectGaps
    case checkConsistency
}

public enum GoalStepStatus: String, Sendable {
    case pending
    case running
    case done
    case failed
}

public enum GoalStatus: String, Sendable {
    case pending
    case running
    case done
    case failed
}
