import Foundation

// MARK: - Intent Parser

/// Lexicon-based intent recognition for the command bar.
/// Fail-closed: unknown input returns .unparsed — never guesses.
public enum IntentParser {

    // MARK: - Input → Intent

    public static func parse(_ text: String, stage: CaseStage) -> ParsedIntent {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return ParsedIntent(kind: .unparsed) }

        let lower = clean.lowercased()

        // Import / add evidence
        if lower.contains("添加") || lower.contains("导入") || lower.contains("拍照")
            || lower.contains("补充") || lower.contains("新增") {
            return ParsedIntent(kind: .importEvidence,
                scope: extractScope(from: clean))
        }

        // Generate / update catalog
        if lower.contains("生成目录") || lower.contains("写目录") || lower.contains("更新目录")
            || lower.contains("重建目录") {
            return ParsedIntent(kind: .generateCatalog)
        }

        // Full review
        if lower.contains("全面复核") || lower.contains("重新分析") || lower.contains("全部重查") {
            return ParsedIntent(kind: .fullReview)
        }

        // Gap detection
        if lower.contains("检查缺口") || lower.contains("还缺什么") || lower.contains("补证")
            || lower.contains("缺失") {
            return ParsedIntent(kind: .detectGaps)
        }

        // Consistency check
        if lower.contains("检查工资") || lower.contains("核对工资") || lower.contains("工资一致")
            || lower.contains("检查金额") {
            return ParsedIntent(kind: .checkConsistency,
                scope: .evidenceCategory(.salary))
        }

        // Severance calculation
        if lower.contains("经济补偿") || lower.contains("赔偿金") || lower.contains("算补偿") {
            return ParsedIntent(kind: .computeSeverance)
        }

        // Citation verification
        if lower.contains("验证引用") || lower.contains("核对引用") || lower.contains("出处") {
            return ParsedIntent(kind: .verifyCitations)
        }

        // Fact statement (contains case-relevant info)
        if lower.contains("工资") || lower.contains("欠薪") || lower.contains("拖欠")
            || lower.contains("合同") || lower.contains("解除") || lower.contains("元")
            || lower.contains("年") && lower.contains("月") {
            return ParsedIntent(kind: .addFact)
        }

        return ParsedIntent(kind: .unparsed)
    }

    private static func extractScope(from text: String) -> IntentScope {
        if text.contains("劳动合同") { return .evidenceCategory(.contract) }
        if text.contains("银行流水") || text.contains("工资") && text.contains("流水") {
            return .evidenceCategory(.salary)
        }
        if text.contains("社保") { return .evidenceCategory(.socialInsurance) }
        return .all
    }
}

// MARK: - Types

public enum IntentKind: String, Sendable {
    case importEvidence
    case generateCatalog
    case detectGaps
    case verifyClaim
    case verifyCitations
    case checkConsistency
    case computeSeverance
    case fullReview
    case addFact
    case unparsed
}

public enum IntentScope: Sendable, Equatable {
    case all
    case claim(String)
    case evidenceCategory(EvidenceCategory)
}

public enum EvidenceCategory: String, Sendable, Equatable {
    case salary, contract, socialInsurance, housingFund, businessReg, other
}

public struct ParsedIntent: Sendable {
    public let kind: IntentKind
    public let scope: IntentScope
    public let originalText: String

    public init(kind: IntentKind, scope: IntentScope = .all, originalText: String = "") {
        self.kind = kind
        self.scope = scope
        self.originalText = originalText
    }

    public var isParsed: Bool { kind != .unparsed }
}

// MARK: - Intent Handler

/// Maps parsed intent to UI action + status message.
public struct IntentHandler {

    public static func handle(
        _ intent: ParsedIntent,
        caseFile: CaseFile
    ) -> IntentResult {
        switch intent.kind {
        case .importEvidence:
            return IntentResult(
                action: .showCamera,
                message: "拍照或选择文件导入证据",
                success: true
            )

        case .generateCatalog:
            let count = caseFile.evidenceItems.filter { $0.sourceOCRText.isEmpty }.count
            if count > 0 {
                return IntentResult(
                    action: .none,
                    message: "有 \(count) 项证据尚未导入源文件，请先拍照导入",
                    success: false
                )
            }
            return IntentResult(
                action: .runAI,
                message: "正在为 \(caseFile.evidenceItems.count) 项证据生成目录…",
                success: true
            )

        case .detectGaps:
            let gaps = findCommonGaps(caseFile)
            if gaps.isEmpty {
                return IntentResult(action: .none, message: "未发现明显证据缺口", success: true)
            }
            for gap in gaps { caseFile.gaps.append(gap) }
            return IntentResult(
                action: .none,
                message: "发现 \(gaps.count) 个证据缺口，已加入待办区",
                success: true
            )

        case .checkConsistency:
            let conflicts = checkSalaryConsistency(caseFile)
            return IntentResult(
                action: .none,
                message: "工资数据检查完成：\(conflicts) 处不一致",
                success: true
            )

        case .computeSeverance:
            return IntentResult(
                action: .none,
                message: "经济补偿金计算：需确认月工资标准和工作年限",
                success: true
            )

        case .verifyCitations:
            return IntentResult(
                action: .runAI,
                message: "正在逐条验证引用出处…",
                success: true
            )

        case .fullReview:
            return IntentResult(
                action: .runAI,
                message: "全面复核中 — 将重新检查所有条目…",
                success: true
            )

        case .addFact:
            return IntentResult(
                action: .none,
                message: "已记录。可输入「生成目录」让 AI 据此更新。",
                success: true
            )

        case .verifyClaim:
            return IntentResult(
                action: .runAI,
                message: "正在审查仲裁请求证据支持…",
                success: true
            )

        case .unparsed:
            return IntentResult(
                action: .none,
                message: "试试：补充银行流水 / 生成目录 / 检查工资 / 全面复核",
                success: false
            )
        }
    }

    // MARK: - Deterministic checks

    private static func findCommonGaps(_ caseFile: CaseFile) -> [GapItem] {
        var gaps: [GapItem] = []
        let names = Set(caseFile.evidenceItems.map { $0.name })
        let checks: [(String, String, String)] = [
            ("劳动合同", "证明劳动关系和工资标准", "全部请求"),
            ("银行流水", "证明实际工资发放", "欠薪相关请求"),
            ("参保证明", "证明劳动关系存续期间", "全部请求"),
        ]
        for (type, purpose, claim) in checks {
            if !names.contains(where: { $0.contains(type) }) {
                gaps.append(GapItem(severity: .high,
                    description: "缺少\(type)",
                    suggestedRemedy: "建议补充\(type)（\(purpose)）",
                    relatedClaim: claim))
            }
        }
        return gaps
    }

    private static func checkSalaryConsistency(_ caseFile: CaseFile) -> Int {
        let salaryItems = caseFile.evidenceItems.filter {
            $0.name.contains("工资") || ($0.proofContentState.displayValue ?? "").contains("元")
        }
        let numbers = salaryItems.flatMap { item -> [String] in
            let pattern = try! NSRegularExpression(pattern: #"\d+\.?\d*"#)
            let text = item.proofContentState.displayValue ?? ""
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
        return Set(numbers).count - 1
    }
}

public struct IntentResult: Sendable {
    public enum Action: Sendable { case none, showCamera, runAI }
    public let action: Action
    public let message: String
    public let success: Bool
}
