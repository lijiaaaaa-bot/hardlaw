import Foundation

// MARK: - Stage Derivation

/// Pure function: given case state, return the derived stage.
/// Never stored — computed from evidence + catalog + gap state.
public enum StageDerivation {

    public static func derive(
        claimsExist: Bool,
        evidenceCount: Int,
        catalogItems: [DerivedStageInput]
    ) -> CaseStage {
        if !claimsExist && evidenceCount == 0 { return .drafting }

        let allDrafted = catalogItems.allSatisfy { $0.isDrafted && !$0.isStale }
        if !allDrafted { return .evidenceCollection }

        let unresolvedGaps = catalogItems.reduce(0) { $0 + $1.unresolvedGapCount }
        if unresolvedGaps > 0 { return .gapResolution }

        let allVerified = catalogItems.allSatisfy { $0.isVerified }
        if !allVerified { return .catalogReview }

        return .readyToFile
    }
}

/// Lightweight input — only the fields derivation needs.
public struct DerivedStageInput: Sendable {
    public var isDrafted: Bool
    public var isStale: Bool
    public var isVerified: Bool
    public var unresolvedGapCount: Int

    public init(isDrafted: Bool = false, isStale: Bool = false,
                isVerified: Bool = false, unresolvedGapCount: Int = 0) {
        self.isDrafted = isDrafted
        self.isStale = isStale
        self.isVerified = isVerified
        self.unresolvedGapCount = unresolvedGapCount
    }
}

// MARK: - Next Action

/// Compute the single recommended next action for a case.
public enum NextAction {

    public static func compute(
        stage: CaseStage,
        catalogItems: [DerivedStageInput],
        unresolvedGaps: [GapItem]
    ) -> String {
        switch stage {
        case .drafting:
            return "描述案件或导入第一份证据"
        case .evidenceCollection:
            let staleCount = catalogItems.filter(\.isStale).count
            if staleCount > 0 { return "\(staleCount) 项待更新" }
            let undrafted = catalogItems.filter { !$0.isDrafted }.count
            return "\(undrafted) 项待生成目录"
        case .catalogReview:
            let unverified = catalogItems.filter { !$0.isVerified }.count
            return "\(unverified) 项待核实确认"
        case .gapResolution:
            if let first = unresolvedGaps.first(where: { !$0.isResolved }) {
                return "补证：\(first.description)"
            }
            return "处理剩余缺口"
        case .readyToFile:
            return "可提交 — 导出证据目录"
        }
    }
}
