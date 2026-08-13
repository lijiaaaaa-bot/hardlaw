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
    /// Each JUDGMENT step maps "blocked" to the same next step as "refuted":
    /// a hard evidence validation failure (e.g. rule-based refs cite a generic
    /// source while statutes require named evidence types) must continue the
    /// procedure instead of aborting it after a single verdict.
    ///
    /// All 13 gap-detection statutes, ordered by 请求权基础 (legal claim grouping)
    /// so the report reads in legal logic order and adjacent statutes share
    /// reasoning chains (e.g. 被迫解除/违法解除/代通知金 are mutually exclusive
    /// termination paths). Mirrors LaborLawStatutes.gapDetectionBook.
    public static let gapDetectionChecks: [(statute: String, step: String)] = [
        // 第一组 劳动关系存续
        ("劳动关系确认", "check_employment"),
        ("工资标准核实", "check_salary_standard"),
        ("双倍工资差额", "check_double_salary"),
        // 第二组 工资债权
        ("拖欠工资", "check_wages"),
        ("加班费", "check_overtime_pay"),
        ("经济补偿金计算", "check_severance"),
        ("加付赔偿金", "check_additional_compensation"),
        // 第三组 劳动关系消灭（互斥解除路径相邻）
        ("被迫解除劳动合同", "check_forced_termination"),
        ("违法解除赔偿金", "check_wrongful_termination"),
        ("代通知金", "check_payment_in_lieu"),
        // 第四组 程序性
        ("仲裁时效", "check_arbitration_limitation"),
        // 第五组 特殊情形
        ("未休年休假工资", "check_unused_annual_leave"),
        ("关联企业混同用工", "check_mixed"),
    ]

    public static func gapDetection() throws -> Procedure {
        let checks = gapDetectionChecks

        var steps: [Step] = []
        for (idx, check) in checks.enumerated() {
            let next = idx + 1 < checks.count ? checks[idx + 1].step : "collect"
            steps.append(Step(
                name: check.step,
                kind: .judgment,
                statutes: [check.statute],
                transitions: ["not_refuted": next, "refuted": next, "blocked": next]
            ))
        }
        steps.append(Step(name: "collect", kind: .code,
            handler: { ctx in
                let gaps = ctx.findings.flatMap { v in v.findings.filter { !$0.isEmpty } }
                ctx.metadata["gap_count"] = JSONValue.number(Double(gaps.count))
            },
            transitions: [:]))

        return try Procedure(
            name: "gap_detection",
            steps: steps,
            maxRounds: steps.count + 1
        )
    }

    // MARK: - Full Review

    /// Combine catalog generation + gap detection in one procedure.
    /// The gap-detection tail wires all 13 statutes (same as `gapDetection()`).
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

        // Gap-detection tail — same grouped check list as `gapDetection()`.
        let checks = gapDetectionChecks
        for (idx, check) in checks.enumerated() {
            let next = idx + 1 < checks.count ? checks[idx + 1].step : "collect"
            steps.append(Step(
                name: check.step,
                kind: .judgment,
                statutes: [check.statute],
                transitions: ["not_refuted": next, "refuted": next, "blocked": next]
            ))
        }
        steps.append(Step(name: "collect", kind: .code,
            handler: { ctx in
                let gaps = ctx.findings.flatMap { v in v.findings.filter { !$0.isEmpty } }
                ctx.metadata["gap_count"] = JSONValue.number(Double(gaps.count))
            },
            transitions: [:]))
        return try Procedure(name: "full_review", steps: steps, maxRounds: itemCount + 14)
    }

    // MARK: - Consistency Check

    /// Cross-check salary amounts across evidence items.
    /// "blocked" maps to "done" like "refuted": hard evidence validation
    /// failure should still complete the check, not abort the procedure.
    public static func salaryConsistency() throws -> Procedure {
        try Procedure(
            name: "salary_check",
            steps: [
                Step(name: "check_salary", kind: .judgment,
                     statutes: ["工资标准核实"],
                     transitions: ["not_refuted": "done", "refuted": "done", "blocked": "done"]),
                Step(name: "done", kind: .code, transitions: [:]),
            ],
            maxRounds: 2
        )
    }
}
