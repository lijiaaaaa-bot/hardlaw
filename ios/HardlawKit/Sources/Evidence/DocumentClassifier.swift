import Foundation

/// Classification taxonomy for labor dispute evidence documents.
/// Each category maps to a `LaborLawStatutes` required-evidence type.
public enum EvidenceCategory: String, CaseIterable, Sendable {
    case laborContract = "书面劳动合同"
    case bankStatement = "工资银行流水"
    case salaryTable = "工资表"
    case socialInsurance = "参保证明"
    case businessRegistration = "工商登记信息"
    case personnelOverlap = "人事混同证据"
    case financialOverlap = "财务混同证据"
    case terminationNotice = "被迫解除通知书"
    case emsReceipt = "EMS邮寄凭证"
    case dismissalNotice = "解除通知书"
    case attendanceRecord = "加班记录/打卡记录"
    case workHistory = "工龄/工作年限证明"
    case annualLeave = "年休假申请/审批记录"
    case wageStandard = "月工资标准"
    case entryDate = "入职日期"
    case terminationDate = "劳动关系终止日期"
    case administrativeDecision = "劳动行政部门责令限期支付决定"
    case housingFund = "住房公积金"
    case penaltyNotice = "行政处罚文书"
    case arrearsStatement = "未发工资统计表"
    case chatRecord = "聊天记录"
    case other = "其他证据"
}

/// Deterministic document classifier — shared by MLX prompts and the rule engine.
/// Scoring: filename keyword ×3, first-line OCR ×2, full OCR ×1.
public enum DocumentClassifier {

    /// Per-category match rules: (filenamePatterns, firstLinePatterns, fullTextPatterns).
    /// Patterns are regex metacharacter-free substrings for simple `contains`.
    private static let rules: [(category: EvidenceCategory, filename: [String], firstLine: [String], fullText: [String])] = [
        (.laborContract, ["劳动合同", "劳动协议", "聘用合同"], ["劳动合同", "劳动协议", "甲方", "乙方", "合同期限"], ["劳动合同", "用人单位", "劳动报酬"]),
        (.bankStatement, ["银行流水", "银行工资", "交易明细", "工资流水", "银行转账"], ["银行", "流水", "交易明细", "工资发放"], ["交易流水号", "借方", "贷方", "账户", "开户银行"]),
        (.salaryTable, ["工资表", "工资单", "薪资表", "工资明细", "薪酬"], ["工资表", "工资单", "姓名", "应发", "实发", "基本工资"], ["应发工资", "实发工资", "基本工资", "岗位工资"]),
        (.socialInsurance, ["参保证明", "社保", "社会保险", "养老", "医保"], ["参保证明", "社会保险", "参保", "缴费基数", "个人权益"], ["参保单位", "缴费基数", "参保人"]),
        (.businessRegistration, ["工商登记", "营业执照", "企业信息", "天眼查", "企查查"], ["统一社会信用代码", "法定代表人", "注册资本", "经营范围"], ["统一社会信用代码", "法定代表人"]),
        (.personnelOverlap, ["人事混同", "人员混同"], ["人事", "混同", "人员交叉", "同时任职"], ["混同用工", "人员"]),
        (.financialOverlap, ["财务混同", "资金混同"], ["财务", "混同", "资金"], ["混同", "资金"]),
        (.terminationNotice, ["被迫解除", "解除劳动关系", "解除通知"], ["被迫解除", "解除劳动关系", "通知书", "劳动合同法"], ["第38条", "被迫", "解除"]),
        (.emsReceipt, ["EMS", "交寄单", "邮寄凭证", "快递单", "邮寄"], ["EMS", "交寄", "快递", "邮件号码", "寄件人", "收件人"], ["EMS", "交寄", "快递"]),
        (.dismissalNotice, ["解除通知", "终止通知", "辞退", "开除"], ["解除", "终止", "通知", "辞退"], ["解除", "终止"]),
        (.attendanceRecord, ["打卡", "考勤", "出勤", "签到"], ["打卡", "考勤", "出勤", "签到", "上下班"], ["打卡", "考勤"]),
        (.workHistory, ["工龄", "工作年限", "工作证明", "入职"], ["工龄", "工作年限", "入职", "参加工作"], ["工龄", "年限", "入职时间"]),
        (.annualLeave, ["年休假", "年假", "休假", "请假"], ["年休假", "年假", "休假审批", "请假"], ["年休假", "休假"]),
        (.wageStandard, ["工资标准", "月工资", "薪资标准"], ["月工资", "工资标准", "薪资"], ["月工资", "工资标准"]),
        (.entryDate, ["入职日期", "入职时间", "报到"], ["入职日期", "入职时间", "报到"], ["入职"]),
        (.terminationDate, ["离职日期", "终止日期", "解除日期"], ["离职", "终止日期", "解除日期"], ["离职", "终止"]),
        (.administrativeDecision, ["责令", "限期支付", "劳动监察", "行政决定"], ["劳动监察", "责令", "限期", "行政"], ["责令", "限期"]),
        (.housingFund, ["公积金", "住房公积金"], ["公积金", "住房公积金", "缴存"], ["住房公积金", "缴存单位"]),
        (.penaltyNotice, ["行政处罚", "行政处理", "劳动监察"], ["行政处罚", "行政处理", "事先告知", "决定书"], ["行政处罚", "行政处理"]),
        (.arrearsStatement, ["欠薪", "拖欠", "未发放", "未发工资", "欠发工资"], ["拖欠", "欠发", "未发放", "欠薪"], ["未发放", "欠薪", "拖欠"]),
        (.chatRecord, ["微信", "聊天", "钉钉", "短信"], ["微信", "聊天记录", "钉钉", "消息"], ["聊天", "消息"]),
    ]

    // MARK: - Public API

    /// Classify a document by filename and OCR content.
    /// Returns nil when no category reaches the minimum confidence threshold.
    public static func classify(fileName: String, ocrText: String) -> EvidenceCategory? {
        let firstLine = ocrText.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""

        var bestScore = 0
        var bestCategory: EvidenceCategory?

        for (category, filenamePats, firstLinePats, fullTextPats) in rules {
            var score = 0

            // Filename hits ×3
            for pat in filenamePats {
                if fileName.localizedCaseInsensitiveContains(pat) {
                    score += 3
                }
            }

            // First-line hits ×2
            for pat in firstLinePats {
                if firstLine.localizedCaseInsensitiveContains(pat) {
                    score += 2
                }
            }

            // Full-text hits ×1
            for pat in fullTextPats {
                if ocrText.localizedCaseInsensitiveContains(pat) {
                    score += 1
                }
            }

            if score > bestScore {
                bestScore = score
                bestCategory = category
            }
        }

        // Require a minimum score to avoid false matches
        guard bestScore >= 2 else { return nil }
        return disambiguateTermination(category: bestCategory, fileName: fileName, ocrText: ocrText)
    }

    /// Multi-category classification — returns top-N candidates for AI prompts.
    /// The AI prompt can present these as a constrained choice list.
    public static func classifyTopN(fileName: String, ocrText: String, n: Int = 3) -> [EvidenceCategory] {
        let firstLine = ocrText.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""

        var scored: [(EvidenceCategory, Int)] = []
        for (category, filenamePats, firstLinePats, fullTextPats) in rules {
            var score = 0
            for pat in filenamePats {
                if fileName.localizedCaseInsensitiveContains(pat) { score += 3 }
            }
            for pat in firstLinePats {
                if firstLine.localizedCaseInsensitiveContains(pat) { score += 2 }
            }
            for pat in fullTextPats {
                if ocrText.localizedCaseInsensitiveContains(pat) { score += 1 }
            }
            if score > 0 {
                scored.append((category, score))
            }
        }
        scored.sort { $0.1 > $1.1 }
        var top = Array(scored.prefix(n).map { $0.0 })

        // Disambiguation: a plain "解除通知书" could be either the worker's
        // forced termination notice or the employer's unilateral dismissal.
        // Promote the corrected category to the top so the AI sees the right
        // candidate first.
        if let corrected = disambiguateTermination(category: top.first, fileName: fileName, ocrText: ocrText),
           let idx = top.firstIndex(of: corrected) {
            top.remove(at: idx)
            top.insert(corrected, at: 0)
        }
        return top
    }

    // MARK: - Termination disambiguation

    /// 被迫解除（劳动者依据《劳动合同法》第38条提出）与单方解除（用人单位辞退）
    /// 在文件名或关键词打分上极易平局，这里用内容信号做二次消歧。
    private static func disambiguateTermination(
        category: EvidenceCategory?,
        fileName: String,
        ocrText: String
    ) -> EvidenceCategory? {
        guard category == .terminationNotice || category == .dismissalNotice else { return category }
        let text = fileName + "\n" + ocrText

        // Forced termination markers — the worker cites a statutory ground to resign.
        let forcedMarkers = ["被迫", "第38条", "第三十八条", "提出解除", "未足额支付劳动报酬", "未依法缴纳社会保险", "以用人单位存在"]
        let isForced = forcedMarkers.contains { text.localizedCaseInsensitiveContains($0) }

        // Employer unilateral dismissal markers.
        let employerMarkers = ["辞退", "开除", "严重违反", "严重失职", "第39条", "第三十九条", "试用期", "严重违纪"]
        let isEmployerFired = employerMarkers.contains { text.localizedCaseInsensitiveContains($0) }

        if isForced {
            return .terminationNotice
        }
        if isEmployerFired && category == .terminationNotice {
            return .dismissalNotice
        }
        return category
    }
}
