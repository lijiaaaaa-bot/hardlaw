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
    case generateCatalog       // needs LLM
    case detectGaps            // local only
    case verifyClaim           // needs LLM
    case verifyCitations       // local only
    case checkConsistency      // local only
    case computeSeverance      // local only
    case fullReview            // needs LLM
    case addFact
    case unparsed
}

/// Which execution backend to use.
public enum ExecutionBackend: Sendable {
    case local    // deterministic: snippet check, number match, gap detect
    case llm      // needs cloud/on-device LLM: drafting, reasoning
}

public extension IntentKind {
    var backend: ExecutionBackend {
        switch self {
        case .importEvidence, .addFact, .unparsed: return .local
        case .detectGaps, .verifyCitations, .checkConsistency, .computeSeverance:
            return .local
        case .generateCatalog, .verifyClaim, .fullReview:
            return .llm
        }
    }
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
            return computeSeverance(caseFile)

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

    // MARK: - 经济补偿金计算（《劳动合同法》第47条）

    /// 经济补偿金 = 月工资标准 × 工作年限。
    /// 依据《劳动合同法》第47条：每满一年支付一个月工资；
    /// 六个月以上不满一年的按一年计算，不满六个月的支付半个月工资。
    private static func computeSeverance(_ caseFile: CaseFile) -> IntentResult {
        let wage = extractMonthlyWage(from: caseFile)
        let years = extractWorkYears(from: caseFile)

        if let wage, let years {
            // 《劳动合同法》第47条：每满一年支付一个月工资；
            // 六个月以上不满一年的按一年计算；不满六个月的支付半个月工资。
            let fullYears = Int(floor(years))
            let remainder = years - Double(fullYears)
            // 每满一年支付一个月工资；六个月以上不满一年按一年计算；
            // 不满六个月支付半个月工资（如 2 年 4 个月 → 2.5 个月工资）
            let compensatedYears: Double
            if remainder >= 0.5 { compensatedYears = Double(fullYears + 1) }
            else if remainder > 0 { compensatedYears = Double(fullYears) + 0.5 }
            else { compensatedYears = Double(fullYears) }
            let amount = wage * compensatedYears
            let detail = years.truncatingRemainder(dividingBy: 1) == 0
                ? "满 \(fullYears) 年 → \(format(compensatedYears)) 个月工资"
                : "\(fullYears) 年 + \(String(format: "%.1f", remainder * 12)) 个月 → 按 \(format(compensatedYears)) 个月工资计算"
            return IntentResult(
                action: .none,
                message: "经济补偿金 = 月工资 \(format(wage)) 元 × \(format(compensatedYears)) 个月 = \(format(amount)) 元（依据《劳动合同法》第47条：\(detail)）",
                success: true
            )
        }
        if let wage {
            return IntentResult(
                action: .none,
                message: "经济补偿金：已提取月工资 \(format(wage)) 元，但未确认工作年限。补充合同或输入如「工作 3 年」。",
                success: false
            )
        }
        if let years {
            return IntentResult(
                action: .none,
                message: "经济补偿金：已确认工作年限 \(format(years)) 年，但未从证据中找到月工资。补充工资表/流水。",
                success: false
            )
        }
        return IntentResult(
            action: .none,
            message: "经济补偿金：未找到月工资和工作年限。补充工资表与劳动合同，或输入如「月工资 8000 元，工作 3 年」。",
            success: false
        )
    }

    /// 从案件证据/请求中提取月工资标准（元/月）。
    /// 优先级：①「月工资 X 元 / X 元/月」等明确表述（含银行流水 OCR）→
    /// ② 工资类证据的证明内容中的唯一金额。
    /// 流水类 OCR 明细只在出现明确月工资模式时使用，避免把单笔金额误当工资标准。
    private static func extractMonthlyWage(from caseFile: CaseFile) -> Double? {
        // ① 明确月工资表述
        let explicitPatterns = [
            #"(?:月工资|月薪|工资标准|月收入|每月|工资)[^\d]{0,6}(\d+(?:\.\d+)?)\s*元"#,
            #"(\d+(?:\.\d+)?)\s*(?:元)?\s*(?:/|／)\s*月"#,
        ]
        for text in allTexts(from: caseFile) {
            for pattern in explicitPatterns {
                if let value = captureNumber(in: text, pattern: pattern) {
                    return value
                }
            }
        }
        // ② 工资类证据中的唯一金额（如工资表/劳动合同的证明内容）
        for item in caseFile.evidenceItems
        where item.name.contains("工资") || item.name.contains("流水") || item.name.contains("合同") {
            if let value = singleNumber(in: item.proofContentState.displayValue ?? "") {
                return value
            }
        }
        return nil
    }

    /// 从案件证据/请求中提取工作年限（年）。
    /// 优先级：①「工作 N 年 / 工龄 N 年」等明确表述 → ② 同一文本中的入职与解除日期之差。
    /// 日期差仅在文本含劳动关系关键词时计算，避免把银行流水的日期跨度误当工作年限。
    private static func extractWorkYears(from caseFile: CaseFile) -> Double? {
        for text in allTexts(from: caseFile) {
            if let value = captureNumber(in: text, pattern: #"(?:工作|工龄|任职|入职|服务)[^\d]{0,6}(\d+(?:\.\d+)?)\s*年"#) {
                return value
            }
        }
        for text in allTexts(from: caseFile)
        where text.contains("入职") || text.contains("工作") || text.contains("解除") || text.contains("离职") {
            if let years = yearsBetweenDates(in: text) {
                return years
            }
        }
        return nil
    }

    /// 解析文本中「20xx年x月」日期对，返回起止时间差（年）。
    private static func yearsBetweenDates(in text: String) -> Double? {
        let pattern = #"20\d{2}\s*年\s*\d{1,2}\s*月"#
        // 正则来自编译期常量，防御性 try?，正常不会失败
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        var months: [Int] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let numbers = String(text[range])
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            guard numbers.count >= 2 else { continue }
            months.append(numbers[0] * 12 + numbers[1])
        }
        guard let first = months.min(), let last = months.max(), last > first else { return nil }
        return Double(last - first) / 12.0
    }

    /// 提取文本中唯一的「X元」金额；出现多个金额时视为无法确认，返回 nil。
    private static func singleNumber(in text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*元"#
        // 正则来自编译期常量，防御性 try?，正常不会失败
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard matches.count == 1,
              let range = Range(matches[0].range(at: 1), in: text),
              let value = Double(text[range]) else { return nil }
        return value
    }

    /// 提取文本中第一个捕获组数字。
    private static func captureNumber(in text: String, pattern: String) -> Double? {
        // 正则来自编译期常量，防御性 try?，正常不会失败
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else { return nil }
        return value
    }

    /// 参与计算的全部文本：案由、仲裁请求、证据名称/证明内容/OCR 原文。
    private static func allTexts(from caseFile: CaseFile) -> [String] {
        var texts: [String] = [caseFile.caseName]
        for item in caseFile.evidenceItems {
            texts.append(item.name)
            texts.append(item.proofContentState.displayValue ?? "")
            texts.append(item.sourceOCRText)
        }
        texts.append(contentsOf: caseFile.claims.map(\.content))
        return texts
    }

    /// 数字展示：整数不带小数位，其余保留两位。
    private static func format(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    // MARK: - Deterministic checks

    /// Fallback 确定性缺口检测 — LLM 缺席时的保底产出。
    /// 检查证据名称，名称不匹配时回退搜索 OCR 内容。
    static func findCommonGaps(_ caseFile: CaseFile) -> [GapItem] {
        var gaps: [GapItem] = []
        var seen = Set<String>()
        let names = Set(caseFile.evidenceItems.map { $0.name })
        let allOCR = caseFile.evidenceItems.map { $0.sourceOCRText }.joined(separator: " ")

        // Map claims to related evidence types
        let hasWageClaim = caseFile.claims.contains { $0.content.contains("工资") || $0.content.contains("报酬") || $0.content.contains("欠薪") }
        let primaryClaim = hasWageClaim ? "欠薪相关请求" : "全部请求"

        let checks: [(keyword: String, type: String, purpose: String, claim: String)] = [
            ("劳动合同", "劳动合同", "证明劳动关系和工资标准", primaryClaim),
            ("银行流水|工资流水", "银行流水/工资流水", "证明实际工资发放金额", primaryClaim),
            ("参保证明|社保", "参保证明/社保记录", "证明劳动关系存续期间", "全部请求"),
            ("解除通知|被迫解除|EMS", "被迫解除通知书及送达凭证", "证明解除程序的合法性", "被迫解除相关请求"),
        ]
        for (keyword, type, purpose, claim) in checks {
            let nameMatch = names.contains { $0.contains(type) || $0.range(of: keyword, options: .regularExpression) != nil }
            let contentMatch = allOCR.range(of: keyword, options: .regularExpression) != nil
            if !nameMatch && !contentMatch {
                let key = "\(type)|\(claim)"
                if seen.insert(key).inserted {
                    gaps.append(GapItem(severity: .high,
                        description: "缺少\(type)",
                        suggestedRemedy: "建议补充\(type)（\(purpose)）",
                        relatedClaim: claim))
                }
            }
        }
        return gaps
    }

    private static func checkSalaryConsistency(_ caseFile: CaseFile) -> Int {
        let salaryItems = caseFile.evidenceItems.filter {
            $0.name.contains("工资") || ($0.proofContentState.displayValue ?? "").contains("元")
        }
        guard salaryItems.count >= 2 else { return 0 }
        var conflicts = 0
        for i in 0..<(salaryItems.count - 1) {
            for j in (i + 1)..<salaryItems.count {
                let a = salaryItems[i].proofContentState.displayValue ?? ""
                let b = salaryItems[j].proofContentState.displayValue ?? ""
                if a != b && !a.isEmpty && !b.isEmpty { conflicts += 1 }
            }
        }
        return conflicts
    }
}

public struct IntentResult: Sendable {
    public enum Action: Sendable { case none, showCamera, runAI }
    public let action: Action
    public let message: String
    public let success: Bool
}
