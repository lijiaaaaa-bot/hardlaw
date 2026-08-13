import Foundation

// MARK: - Statute Exclusion Invariant

/// 跨法条互斥 invariant(表驱动,可扩展)。
///
/// 法律依据:
/// - 违法解除赔偿金(2N, 第87条)与 经济补偿金(N, 第47条)不能兼得
/// - 违法解除赔偿金(2N, 第87条)与 代通知金(N+1, 第40条)不能兼得
/// - 经济补偿 N 与 代通知金 N+1 **不**互斥(第40条合法解除补偿 = N+1)
///
/// 每组内:批准其中一个后,其余再被批准即确定性拒绝,不让 LLM 同时主张
/// 互斥请求权。这是「最小可靠约束集」的代码化实现。
public enum StatuteExclusions {

    /// 互斥对表: (当前批准的 statute, 与之互斥的 statute, 拒绝说明)。
    /// 双向各一条;新增互斥对时在此追加即可。
    public static let groups: [(statute: String, excludes: String, note: String)] = [
        // 2N 与 N 互斥(第87条:赔偿金与经济补偿不能兼得)
        ("违法解除赔偿金", "经济补偿金计算",
         "第87条违法解除赔偿(2N)与第47条经济补偿(N)不能兼得，已拒绝后者"),
        ("经济补偿金计算", "违法解除赔偿金",
         "第47条经济补偿(N)与第87条违法解除赔偿(2N)不能兼得，已拒绝后者"),
        // 2N 与 N+1 互斥(第87条 vs 第40条:违法解除与合法解除路径互斥)
        ("违法解除赔偿金", "代通知金",
         "第87条违法解除赔偿(2N)与第40条代通知金(N+1)不能兼得，已拒绝后者"),
        ("代通知金", "违法解除赔偿金",
         "第40条代通知金(N+1)与第87条违法解除赔偿(2N)不能兼得，已拒绝后者"),
    ]

    /// 对 verdict 执行互斥检查:若本步批准 `stepStatutes` 中的法条,
    /// 而先前已批准其互斥方,则确定性 reconcile(改 refuted + 互斥 finding)。
    /// 返回 reconciled 的 verdict;无冲突时原样返回。
    public static func enforce(
        verdict: Verdict,
        approvedStatutes: [String],
        stepStatutes: Set<String>
    ) -> Verdict {
        let approved = Set(approvedStatutes)
        for pair in groups {
            if stepStatutes.contains(pair.statute) && approved.contains(pair.excludes) {
                var v = verdict
                v.refuted = true
                v.blockingKind = BlockingKind.contradiction
                v.findings.append(Finding(
                    kind: "bug", location: "invariant/exclusion",
                    detail: "\(pair.note)（先前已批准「\(pair.excludes)」）"))
                v.fallbackNote = pair.note
                return v
            }
        }
        return verdict
    }
}
