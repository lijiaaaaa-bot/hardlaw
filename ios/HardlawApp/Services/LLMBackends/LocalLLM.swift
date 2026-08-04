import Foundation
import HardlawKit

// MARK: - LocalLLM

/// 本地规则引擎后端：为劳动法证据起草提供确定性的关键事实提取。
///
/// 包装 HardlawKit 的 `RuleBasedLLM`，注入劳动法证据领域的规则配置
/// （金额、日期等），并在此之上完成：
///   1. 从 OCR 原文中逐字提取关键事实（日期、金额、姓名、证据类型）；
///   2. 生成结构化中文「证明内容」——所有引用数字与原文逐字一致；
///   3. 按证据类型关键词映射「证明目的」到可能的仲裁请求；
///   4. 检测缺失的关键证据类型与无法核对的证据。
///
/// 设计约束：不发起任何网络请求，全部为确定性规则，可在离线环境运行。
/// 与 LawAgent 的 Reflection 校验配合：凡此处引用的数字必然可在原文中找到。
@MainActor
public final class LocalLLM {

    /// 金额提取规则：匹配「数字 + 元」的金额表述。
    private static let amountRule = try! RuleBasedLLM.Rule(
        violationName: "amount", pattern: #"\d+\.?\d*\s*元"#, severity: "low"
    )

    /// 日期提取规则：匹配「年月日」格式的完整日期。
    private static let dateRule = try! RuleBasedLLM.Rule(
        violationName: "date", pattern: #"\d{4}年\d{1,2}月\d{1,2}日"#, severity: "low"
    )

    /// 证据类型关键词表（按优先级排序：先匹配更具体的类型）。
    private static let docTypeKeywords: [(keyword: String, docType: String)] = [
        ("解除劳动合同", "解除/终止劳动合同通知书"),
        ("终止劳动合同", "解除/终止劳动合同通知书"),
        ("劳动合同", "劳动合同"),
        ("银行流水", "银行流水"),
        ("工资发放记录", "工资发放记录"),
        ("参保证明", "参保证明"),
        ("参保记录", "参保证明"),
        ("社保", "社保参保记录"),
        ("工资表", "工资表"),
        ("工资条", "工资表"),
        ("考勤", "考勤记录"),
        ("加班", "加班记录"),
        ("裁决书", "仲裁裁决书"),
        ("判决书", "法院判决书"),
        ("调解书", "调解书"),
        ("仲裁申请", "仲裁申请书"),
        ("身份证", "身份证复印件"),
        ("营业执照", "营业执照"),
        ("微信", "微信聊天记录"),
        ("聊天记录", "聊天记录"),
        ("录音", "录音资料"),
        ("邮件", "电子邮件"),
        ("借条", "借条"),
        ("欠条", "欠条"),
        ("收据", "收据"),
        ("发票", "发票"),
    ]

    /// 底层规则引擎实例（本类的规则权威来源）。
    private let ruleLLM: RuleBasedLLM

    public init() {
        self.ruleLLM = RuleBasedLLM(rules: [Self.amountRule, Self.dateRule])
    }

    // MARK: - 目录条目起草

    /// 为单个证据起草「证明内容」与「证明目的」。
    ///
    /// - Parameters:
    ///   - ocrText: Vision OCR 提取的源文件文字（唯一事实来源）。
    ///   - itemName: 证据名称（证据目录中用户填写）。
    ///   - claims: 仲裁请求列表（用于无类型映射时的兜底关联）。
    /// - Returns: `(proofContent, proofPurpose)` —— 中文描述，引用的数字逐字取自原文。
    public func draftCatalogEntry(
        ocrText: String,
        itemName: String,
        claims: [String]
    ) async -> (proofContent: String, proofPurpose: String) {
        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 无源文字：无法起草，标记待人工填写
        guard !trimmed.isEmpty else {
            return (
                proofContent: "待人工填写：该证据暂无源文件文字（OCR 为空）",
                proofPurpose: "证明\(itemName)相关事实"
            )
        }

        // STEP 1: 逐字提取关键事实（提取结果均为原文子串，可验证）
        let dates = dedupe(extractMatches(of: Self.dateRule.regex, in: trimmed))
        let amounts = dedupe(extractMatches(of: Self.amountRule.regex, in: trimmed))
        let names = dedupe(extractNames(in: trimmed))
        let docType = detectDocType(itemName: itemName, ocrText: trimmed)

        // STEP 2: 生成「证明内容」——结构化中文描述，数字逐字引用
        let heading: String
        if let docType = docType {
            heading = "该证据为\(docType)"
        } else {
            heading = "该证据为证据目录所载「\(itemName)」"
        }

        var factLines: [String] = []
        if !dates.isEmpty {
            factLines.append("载明日期：\(dates.joined(separator: "、"))")
        }
        if !amounts.isEmpty {
            factLines.append("载明金额：\(amounts.joined(separator: "、"))")
        }
        if !names.isEmpty {
            factLines.append("涉及人员：\(names.joined(separator: "、"))")
        }

        // 原文摘录：逐字引用原文片段（不截断数字）
        let snippet = verbatimSnippet(from: trimmed, maxLength: 120)
        if !snippet.isEmpty {
            factLines.append("原文摘录：\(snippet)")
        }

        var proofContent = heading + "。"
        if !factLines.isEmpty {
            proofContent += "\n" + factLines.joined(separator: "\n")
        }

        // STEP 3: 生成「证明目的」——按证据类型关键词映射到可能的法律请求
        let proofPurpose: String
        if let docType = docType {
            proofPurpose = Self.purpose(for: docType, itemName: itemName)
        } else if !claims.isEmpty {
            proofPurpose = "证明\(itemName)相关事实，与仲裁请求「\(claims.joined(separator: "；"))」相关"
        } else {
            proofPurpose = "证明\(itemName)相关事实"
        }

        return (proofContent: proofContent, proofPurpose: proofPurpose)
    }

    // MARK: - 缺口检测

    /// 检测证据缺口：缺失的关键证据类型 + 无法核对的证据。
    ///
    /// - Parameters:
    ///   - evidenceNames: 全部证据名称（与 evidenceTexts 一一对应）。
    ///   - evidenceTexts: 各证据的 OCR 源文字（与 evidenceNames 一一对应）。
    /// - Returns: 中文缺口描述列表；无缺口时为空数组。
    public func detectGaps(evidenceNames: [String], evidenceTexts: [String]) async -> [String] {
        var gaps: [String] = []

        // 1. 关键证据类型缺失检查
        let requiredTypes: [(keyword: String, description: String)] = [
            ("劳动合同", "缺少劳动合同：无法证明劳动关系及工资标准"),
            ("银行流水", "缺少银行流水：无法证明实际工资发放情况"),
            ("参保证明", "缺少参保证明：无法证明劳动关系存续期间"),
            ("工资表", "缺少工资表/工资条：无法核对工资构成与标准"),
            ("考勤", "缺少考勤记录：无法核实出勤与加班情况"),
            ("解除劳动合同", "缺少解除/终止劳动合同通知书：无法证明解除原因"),
        ]
        for check in requiredTypes where !evidenceNames.contains(where: { $0.contains(check.keyword) }) {
            gaps.append(check.description)
        }

        // 2. 逐项核对证据的源文字
        for (index, name) in evidenceNames.enumerated() {
            let text = index < evidenceTexts.count ? evidenceTexts[index] : ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // 2a. OCR 为空 → 无法核对
            guard !trimmed.isEmpty else {
                gaps.append("证据「\(name)」没有可核对的源文件文字（OCR 为空），请重新识别或人工录入")
                continue
            }

            // 2b. 用规则引擎核对关键要素（金额/日期）是否存在于原文
            let hasAmount = Self.amountRule.regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
            ) != nil
            let hasDate = Self.dateRule.regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
            ) != nil
            if !hasAmount && !hasDate {
                gaps.append("证据「\(name)」原文中未检测到金额或日期等关键要素，建议人工核对")
            }
        }

        return gaps
    }

    // MARK: - 关键事实提取（私有）

    /// 提取姓名：优先「称呼 + 冒号/冒号 + 2~4 个汉字」格式，再匹配公司主体名称。
    private func extractNames(in text: String) -> [String] {
        var names: [String] = []
        let personPattern = #"(?:姓名|名字|申请人|被申请人|劳动者|员工|本人|甲方|乙方)[：:]\s*([一-龥]{2,4})"#
        if let regex = try? NSRegularExpression(pattern: personPattern, options: []) {
            names.append(contentsOf: captureGroups(of: regex, in: text))
        }
        let companyPattern = #"([一-龥]{2,12}(?:有限公司|有限责任公司|集团|公司|工厂|中心|事务所))"#
        if let regex = try? NSRegularExpression(pattern: companyPattern, options: []) {
            names.append(contentsOf: captureGroups(of: regex, in: text))
        }
        return names
    }

    /// 检测证据类型：先在证据名称中匹配关键词，再回退到 OCR 原文。
    private func detectDocType(itemName: String, ocrText: String) -> String? {
        for entry in Self.docTypeKeywords {
            if itemName.contains(entry.keyword) || ocrText.contains(entry.keyword) {
                return entry.docType
            }
        }
        return nil
    }

    /// 原文摘录：取原文前 maxLength 个字符；仅在非截断位置切分，避免切断数字。
    private func verbatimSnippet(from text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return "「\(text)」" }
        var end = text.index(text.startIndex, offsetBy: maxLength)
        // 若在数字中间截断，则回退到上一个非数字字符
        while end > text.startIndex, end < text.endIndex {
            let prev = text.index(before: end)
            let nextChar = text[end]
            let prevChar = text[prev]
            if nextChar.isNumber || prevChar.isNumber {
                end = prev
            } else {
                break
            }
        }
        let prefix = String(text[..<end])
        return "「\(prefix)……」"
    }

    // MARK: - 正则辅助

    /// 提取正则的全部匹配文本（原文子串，按出现顺序去重）。
    private func extractMatches(of regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            // 去除匹配到的首尾空白，保留数字本身（仍是原文的子串）
            return String(text[matchRange]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// 提取正则首个捕获组的文本（原文子串）。
    private func captureGroups(of regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[groupRange])
        }
    }

    /// 去重（保持首次出现顺序）。
    private func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - 证明目的映射（私有）

    /// 按证据类型映射到可能支持的仲裁请求。
    private static func purpose(for docType: String, itemName: String) -> String {
        switch docType {
        case "劳动合同":
            return "证明双方存在劳动关系，载明工作岗位、劳动报酬、合同期限等约定，支持确认劳动关系及工资标准相关请求"
        case "解除/终止劳动合同通知书":
            return "证明劳动关系解除的时间与原因，支持主张经济补偿金或违法解除赔偿金相关请求"
        case "银行流水":
            return "证明用人单位实际支付工资的金额与时间，支持核对拖欠工资差额相关请求"
        case "工资发放记录":
            return "证明工资发放情况与发放主体，支持核对欠薪金额相关请求"
        case "参保证明":
            return "证明劳动关系的存续期间及参保情况，支持确认劳动关系相关请求"
        case "社保参保记录":
            return "证明劳动关系存续期间及社保缴纳情况，支持社保补缴相关请求"
        case "工资表":
            return "证明工资构成与发放标准，支持计算拖欠工资及加班费差额相关请求"
        case "考勤记录":
            return "证明劳动者出勤与工作时长，支持加班费及工资计算相关请求"
        case "加班记录":
            return "证明加班事实与加班时长，支持主张加班费相关请求"
        case "仲裁裁决书":
            return "证明争议已经仲裁前置程序处理及裁决结果，支持本案请求"
        case "法院判决书":
            return "证明相关纠纷的生效裁判结果，支持本案事实认定"
        case "调解书":
            return "证明双方此前达成的调解协议内容，支持相关请求"
        case "仲裁申请书":
            return "证明申请人提出的仲裁请求及争议事实，支持本案请求"
        case "身份证复印件":
            return "证明劳动者主体身份信息，支持主体资格审查"
        case "营业执照":
            return "证明用人单位主体资格与登记信息，支持确定被申请人主体"
        case "微信聊天记录":
            return "证明双方就工资、工作安排等事项沟通的事实，支持相关请求"
        case "聊天记录":
            return "证明双方沟通协商过程及关键事实，支持相关请求"
        case "录音资料":
            return "证明双方就争议事项沟通的口头内容，支持相关事实认定"
        case "电子邮件":
            return "证明双方书面往来及工作安排内容，支持相关请求"
        case "借条":
            return "证明借款金额与还款约定，支持欠款返还相关请求"
        case "欠条":
            return "证明欠款事实与金额，支持欠款支付相关请求"
        case "收据":
            return "证明款项收付事实与金额，支持款项往来相关请求"
        case "发票":
            return "证明交易金额与发生时间，支持款项往来相关请求"
        default:
            return "证明\(itemName)所载事实，供仲裁庭查明案件情况"
        }
    }
}
