import Foundation

// MARK: - Court Procedure Factory

/// Builds Procedure instances for the app's intents.
/// Each intent maps to a state machine that Court.hear() executes.
public enum CourtProcedures {

    // MARK: - Catalog Generation

    /// Build a procedure that generates proofContent/proofPurpose for each evidence item.
    /// Each item gets its own JUDGMENT step; all steps are sequential.
    public static func catalogGeneration(itemCount: Int) throws -> Procedure {
        var steps: [Step] = []
        for i in 1...itemCount {
            steps.append(Step(
                name: "draft_item_\(i)",
                kind: .judgment,
                statutes: [],
                transitions: i < itemCount
                    ? ["not_refuted": "draft_item_\(i+1)", "refuted": "draft_item_\(i+1)"]
                    : ["not_refuted": "collect_results", "refuted": "collect_results"]
            ))
        }
        steps.append(Step(name: "collect_results", kind: .code, transitions: [:]))
        return try Procedure(name: "catalog_generation", steps: steps, maxRounds: itemCount + 2)
    }

    // MARK: - Gap Detection

    /// Build a procedure that checks for evidence gaps using the labor law statutes.
    public static func gapDetection() throws -> Procedure {
        try Procedure(
            name: "gap_detection",
            steps: [
                Step(name: "check_employment", kind: .judgment,
                     statutes: ["劳动关系确认"],
                     transitions: ["not_refuted": "check_wages", "refuted": "check_wages"]),
                Step(name: "check_wages", kind: .judgment,
                     statutes: ["拖欠工资"],
                     transitions: ["not_refuted": "check_mixed", "refuted": "check_mixed"]),
                Step(name: "check_mixed", kind: .judgment,
                     statutes: ["关联企业混同用工"],
                     transitions: ["not_refuted": "collect", "refuted": "collect"]),
                Step(name: "collect", kind: .code,
                     handler: { ctx in
                         let gaps = ctx.findings.flatMap { v in v.findings.filter { !$0.isEmpty } }
                         ctx.metadata["gap_count"] = JSONValue.number(Double(gaps.count))
                     },
                     transitions: [:]),
            ],
            maxRounds: 5
        )
    }

    // MARK: - Full Review

    /// Combine catalog generation + gap detection in one procedure.
    public static func fullReview(itemCount: Int) throws -> Procedure {
        var steps: [Step] = []
        for i in 1...itemCount {
            steps.append(Step(
                name: "draft_\(i)",
                kind: .judgment,
                statutes: [],
                transitions: i < itemCount
                    ? ["not_refuted": "draft_\(i+1)", "refuted": "draft_\(i+1)"]
                    : ["not_refuted": "check_employment", "refuted": "check_employment"]
            ))
        }
        steps.append(Step(name: "check_employment", kind: .judgment,
            statutes: ["劳动关系确认"],
            transitions: ["not_refuted": "check_wages", "refuted": "check_wages"]))
        steps.append(Step(name: "check_wages", kind: .judgment,
            statutes: ["拖欠工资"],
            transitions: ["not_refuted": "check_mixed", "refuted": "check_mixed"]))
        steps.append(Step(name: "check_mixed", kind: .judgment,
            statutes: ["关联企业混同用工"],
            transitions: ["not_refuted": "collect", "refuted": "collect"]))
        steps.append(Step(name: "collect", kind: .code,
            handler: { ctx in
                let gaps = ctx.findings.flatMap { v in v.findings.filter { !$0.isEmpty } }
                ctx.metadata["gap_count"] = JSONValue.number(Double(gaps.count))
            },
            transitions: [:]))
        return try Procedure(name: "full_review", steps: steps, maxRounds: itemCount + 5)
    }

    // MARK: - Consistency Check

    /// Cross-check salary amounts across evidence items.
    public static func salaryConsistency() throws -> Procedure {
        try Procedure(
            name: "salary_check",
            steps: [
                Step(name: "check_salary", kind: .judgment,
                     statutes: ["工资标准核实"],
                     transitions: ["not_refuted": "done", "refuted": "done"]),
                Step(name: "done", kind: .code, transitions: [:]),
            ],
            maxRounds: 2
        )
    }
}
