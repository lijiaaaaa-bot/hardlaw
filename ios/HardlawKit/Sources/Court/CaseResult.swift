import Foundation

// MARK: - CaseResult

/// The final outcome of a case heard by the Court.
/// Mirrors Python `hardlaw.court.CaseResult`.
public struct CaseResult: Sendable, Equatable {
    /// The case identifier.
    public var caseId: String
    /// All verdicts collected during the procedure.
    public var verdicts: [Verdict]
    /// Final disposition of the case.
    public var finalDisposition: Disposition
    /// Human-readable summary of the outcome.
    public var reason: String
    /// Total rounds executed.
    public var roundCount: Int

    public init(
        caseId: String,
        verdicts: [Verdict] = [],
        finalDisposition: Disposition = .rejected,
        reason: String = "",
        roundCount: Int = 0
    ) {
        self.caseId = caseId
        self.verdicts = verdicts
        self.finalDisposition = finalDisposition
        self.reason = reason
        self.roundCount = roundCount
    }

    /// Final case disposition.
    /// Mirrors Python final_disposition string values.
    public enum Disposition: String, Sendable, Equatable, Codable {
        case approved
        case rejected
        case blocked
        case stalled
        case maxRounds = "max_rounds"
        /// Terminal step name used as disposition (Python behavior).
        case terminalStep

        /// Create from a step name, mapping known step names and falling back to .terminalStep.
        public static func fromStepName(_ name: String) -> Disposition {
            switch name {
            case "approved", "approve_content": return .approved
            case "rejected", "reject_content": return .rejected
            case "blocked", "block_content": return .blocked
            case "warned", "warn_author": return .rejected
            default: return .terminalStep
            }
        }
    }
}
