import Foundation
import HardlawKit

// MARK: - LawAgent

/// The AI agent for legal evidence review.
///
/// Implements the Reflection pattern from Grok Build:
///   1. **Draft** (LLM): Generate proof content/purpose from OCR evidence
///   2. **Verify** (EvidenceValidator): Check every cited fact exists in source
///   3. **Reflect**: If verification fails, feed failure context back → retry
///   4. **Finalize**: Apply machineDraft to FieldState, create GapItem for unresolved issues
///
/// All steps are hard-constrained by Statute → Procedure → Evidence → Verdict → Court.
/// NOT an actor — @Observable models are MainActor-bound, so agent runs on MainActor too.
@MainActor
public final class LawAgent {

    /// Progress updates for UI binding.
    public struct Progress: Sendable {
        public let step: String
        public let detail: String
        public let fraction: Double
    }

    // MARK: - Catalog Generation

    /// Generate proofContent/proofPurpose for a single evidence item.
    /// Uses the Reflection pattern: draft → verify → retry if needed.
    public func generateCatalogEntry(
        item: EvidenceItem,
        claimContext: [ClaimItem],
        progress: @escaping @Sendable (Progress) -> Void
    ) async {
        let ocrText = item.sourceOCRText
        guard !ocrText.trimmingCharacters(in: .whitespaces).isEmpty else {
            progress(Progress(step: "跳过", detail: "证据\(item.number) 无源文件文字", fraction: 1))
            return
        }

        // STEP 1: Draft
        progress(Progress(step: "分析中", detail: "证据\(item.number) — 提取关键信息", fraction: 0.2))
        let draft = await draftCatalogContent(ocrText: ocrText, itemName: item.name, claims: claimContext)

        // STEP 2: Verify — check every number in draft exists in source
        progress(Progress(step: "验证中", detail: "逐字核对引用", fraction: 0.6))
        let numbers = extractNumbers(from: draft.proofContent + " " + draft.proofPurpose)
        var unverifiedNumbers: [String] = []
        for num in numbers {
            if !ocrText.contains(num) {
                unverifiedNumbers.append(num)
            }
        }

        // STEP 3: Reflect — if numbers don't match, retry once with failure context
        if !unverifiedNumbers.isEmpty {
            progress(Progress(step: "修正中", detail: "\(unverifiedNumbers.count) 处数字与原文不一致，重新生成", fraction: 0.7))
            let corrected = await draftWithCorrection(
                ocrText: ocrText, itemName: item.name,
                failedNumbers: unverifiedNumbers, previousDraft: draft
            )
            // Verify again
            let correctedNumbers = extractNumbers(from: corrected.proofContent + " " + corrected.proofPurpose)
            let stillUnverified = correctedNumbers.filter { !ocrText.contains($0) }
            if stillUnverified.isEmpty {
                await applyDraft(corrected, to: item)
                progress(Progress(step: "完成", detail: "证据\(item.number) — 已验证通过", fraction: 1))
            } else {
                // Accept the draft but mark stale for human review
                await applyDraft(corrected, to: item)
                item.proofContentState.stale = true
                progress(Progress(step: "需复核", detail: "证据\(item.number) — \(stillUnverified.count) 处待人工确认", fraction: 1))
            }
        } else {
            // All numbers verified → apply
            await applyDraft(draft, to: item)
            progress(Progress(step: "完成", detail: "证据\(item.number) — 全部引用已验证", fraction: 1))
        }
    }

    // MARK: - Gap Detection

    /// Detect evidence gaps using the Court + Statute pipeline.
    /// Returns GapItems for missing or inconsistent evidence.
    public func detectGaps(
        caseFile: CaseFile,
        progress: @escaping @Sendable (Progress) -> Void
    ) async -> [GapItem] {
        progress(Progress(step: "分析中", detail: "检测证据缺口", fraction: 0.3))

        // Build case data from all evidence
        var caseData: [String: JSONValue] = [
            "objective": .string("核实\(caseFile.caseName)的证据完整性"),
        ]
        for item in caseFile.evidenceItems {
            if !item.sourceOCRText.isEmpty {
                caseData["evidence_\(item.number)"] = .string(item.sourceOCRText)
            }
            if let content = item.proofContentState.displayValue, !content.isEmpty {
                caseData["catalog_\(item.number)"] = .string(content)
            }
        }
        for claim in caseFile.claims {
            caseData["claim_\(claim.claimNumber)"] = .string(claim.content)
        }

        // Build procedure with labor law statutes
        guard let procedure = try? GapDetectionProcedure.build(for: caseFile) else {
            return []
        }

        // RuleBasedLLM for on-device gap detection
        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let court = Court(statutes: GapDetectionStatutes.all, procedure: procedure, llm: llm)

        progress(Progress(step: "审理中", detail: "逐项检查证据要求", fraction: 0.6))
        let result = await court.hear(caseData: caseData)

        progress(Progress(step: "汇总", detail: "整理发现", fraction: 0.9))

        // Convert findings to GapItems
        var gaps: [GapItem] = []
        for verdict in result.verdicts {
            for finding in verdict.findings where !finding.isEmpty {
                let severity: GapSeverity = finding.kind == "gap" ? .high : .medium
                gaps.append(GapItem(
                    severity: severity,
                    description: finding.detail,
                    suggestedRemedy: verdict.reasoning,
                    relatedClaim: finding.location
                ))
            }
        }

        // Also check standard gaps
        gaps.append(contentsOf: checkStandardGaps(caseFile))

        return gaps
    }

    // MARK: - Full Review

    /// Run all checks: regenerate catalog + detect gaps + verify consistency.
    public func fullReview(
        caseFile: CaseFile,
        progress: @escaping @Sendable (Progress) -> Void
    ) async {
        let total = Double(caseFile.evidenceItems.count)
        for (i, item) in caseFile.evidenceItems.enumerated() {
            await generateCatalogEntry(
                item: item,
                claimContext: caseFile.claims,
                progress: { p in
                    progress(Progress(
                        step: p.step,
                        detail: p.detail,
                        fraction: Double(i) / total + p.fraction / total
                    ))
                }
            )
        }

        progress(Progress(step: "缺口检测", detail: "检查证据完整性", fraction: 0.9))
        let gaps = await detectGaps(caseFile: caseFile, progress: { _ in })
        for gap in gaps { caseFile.gaps.append(gap) }

        progress(Progress(step: "完成", detail: "复核结束", fraction: 1))
    }

    // MARK: - Private: Draft + Verify + Reflect

    private func draftCatalogContent(
        ocrText: String,
        itemName: String,
        claims: [ClaimItem]
    ) async -> CatalogDraft {
        let claimSummary = claims.map { "请求\($0.claimNumber): \($0.content)" }.joined(separator: "\n")
        let prompt = """
        你是劳动法律师助理。根据以下证据内容，为证据目录撰写「证明内容」和「证明目的」。

        ## 证据名称
        \(itemName)

        ## 原始证据文字（OCR提取）
        \(String(ocrText.prefix(3000)))

        ## 仲裁请求
        \(claimSummary.isEmpty ? "待确认" : claimSummary)

        ## 要求
        1. 证明内容：客观描述该证据显示了什么事实。引用金额、日期、姓名时必须与原文逐字一致。
        2. 证明目的：说明该证据支持哪项仲裁请求。
        3. 如果原文中有数字，必须在证明内容中引用且与原文完全一致。

        输出JSON：
        {"proofContent": "...", "proofPurpose": "..."}
        """

        return await callLLM(prompt: prompt, fallback: CatalogDraft(
            proofContent: "待人工填写",
            proofPurpose: "证明\(itemName)相关事实"
        ))
    }

    private func draftWithCorrection(
        ocrText: String,
        itemName: String,
        failedNumbers: [String],
        previousDraft: CatalogDraft
    ) async -> CatalogDraft {
        let prompt = """
        上一次生成的证明内容中，以下数字与原文不一致：
        \(failedNumbers.joined(separator: "、"))

        原文内容：
        \(String(ocrText.prefix(3000)))

        请修正证明内容和证明目的，确保所有数字与原文逐字一致。
        输出JSON：{"proofContent": "...", "proofPurpose": "..."}
        """

        return await callLLM(prompt: prompt, fallback: previousDraft)
    }

    // MARK: - LLM call

    /// Deterministic on-device generation (no real LLM backend connected yet).
    ///
    /// Anti-hallucination rule: every number cited in the output is copied
    /// verbatim from the OCR text in the prompt — never approximated, rounded,
    /// or paraphrased. The Reflection verification in `generateCatalogEntry`
    /// re-checks every number against the source before the draft is applied.
    private func callLLM(prompt: String, fallback: CatalogDraft) async -> CatalogDraft {
        guard let ocrText = extractOCRText(from: prompt), !ocrText.isEmpty else {
            return fallback
        }

        let facts = extractFacts(from: ocrText, itemName: extractItemName(from: prompt))
        let claims = extractClaims(from: prompt)

        return CatalogDraft(
            proofContent: buildProofContent(facts: facts, ocrText: ocrText),
            proofPurpose: buildProofPurpose(ocrText: ocrText, claims: claims, facts: facts)
        )
    }

    // MARK: - Prompt parsing

    private func extractOCRText(from prompt: String) -> String? {
        if let text = extractSection(from: prompt, after: "## 原始证据文字", until: "## 仲裁请求") {
            return text
        }
        // Correction prompt uses a different layout
        return extractSection(from: prompt, after: "原文内容：", until: "请修正")
    }

    private func extractItemName(from prompt: String) -> String {
        extractSection(from: prompt, after: "## 证据名称", until: "## 原始证据文字") ?? ""
    }

    private func extractClaims(from prompt: String) -> [(number: Int, text: String)] {
        guard let claimsText = extractSection(from: prompt, after: "## 仲裁请求", until: "## 要求") else {
            return []
        }
        let pattern = try! NSRegularExpression(pattern: #"请求(\d+)[：:]?\s*(.+)"#)
        var claims: [(number: Int, text: String)] = []
        for line in claimsText.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line),
                  let number = Int(line[numberRange]) else { continue }
            claims.append((number: number, text: String(line[textRange])))
        }
        return claims
    }

    /// Extract the content between two markers in a prompt, or nil if absent.
    private func extractSection(from text: String, after marker: String, until endMarker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        var remainder = text[start.upperBound...]
        if let newline = remainder.firstIndex(of: "\n") {
            remainder = remainder[remainder.index(after: newline)...]
        }
        if let endRange = remainder.range(of: endMarker) {
            remainder = remainder[..<endRange.lowerBound]
        }
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Fact extraction

    /// Key facts extracted verbatim from the OCR text.
    private struct ExtractedFacts {
        var documentTypes: [String] = []
        var names: [String] = []
        var dates: [String] = []
        /// Amounts with label context when available, e.g. "应发工资合计7550元".
        var amounts: [String] = []
    }

    private func extractFacts(from ocrText: String, itemName: String) -> ExtractedFacts {
        var facts = ExtractedFacts()

        // 1. Document type — the file name is the strongest signal, then OCR keywords
        let nameTypes = Self.documentTypeKeywords.filter { itemName.contains($0) }
        let ocrTypes = Self.documentTypeKeywords.filter { ocrText.contains($0) }
        facts.documentTypes = Array((nameTypes.isEmpty ? ocrTypes : nameTypes).prefix(2))

        // 2. Names — only after explicit role markers, to avoid misattribution
        let fullRange = NSRange(ocrText.startIndex..., in: ocrText)
        let namePattern = try! NSRegularExpression(
            pattern: #"(申请人|被申请人|甲方|乙方|用人单位|劳动者|员工|姓名|法定代表人|负责人|委托代理人|单位名称|公司名称|户名|收款人|付款人)(?:[：:][ \t　]*|[ \t　]+)([^\s，。；、,.!?！？;()（）【】]{2,24})"#)
        var seenNames = Set<String>()
        for match in namePattern.matches(in: ocrText, range: fullRange) {
            guard let nameRange = Range(match.range(at: 2), in: ocrText) else { continue }
            let name = String(ocrText[nameRange]).trimmingCharacters(in: .whitespaces)
            guard name.range(of: #"[一-龥]"#, options: .regularExpression) != nil,
                  !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            facts.names.append(name)
            if facts.names.count >= 2 { break }
        }

        // 3. Dates — full dates preferred over year-month
        let datePattern = try! NSRegularExpression(
            pattern: #"\d{4}年\d{1,2}月\d{1,2}日|\d{4}年\d{1,2}月|\d{4}[-/.]\d{1,2}[-/.]\d{1,2}"#)
        var seenDates = Set<String>()
        for match in datePattern.matches(in: ocrText, range: fullRange) {
            guard let r = Range(match.range, in: ocrText) else { continue }
            let date = String(ocrText[r])
            guard !seenDates.contains(date) else { continue }
            seenDates.insert(date)
            facts.dates.append(date)
            if facts.dates.count >= 3 { break }
        }

        // 4. Amounts — labeled context preferred ("应发工资合计：7550元"),
        //    then bare amounts ("7550元", "3.5万元")
        let labeledPattern = try! NSRegularExpression(
            pattern: #"([一-龥]{2,12})([：:][ \t　]*|[ \t　]+)((?:[¥￥])?\d+(?:\.\d+)?\s*(?:万元|万|元))"#)
        let plainPattern = try! NSRegularExpression(
            pattern: #"(?:[¥￥])?\d+(?:\.\d+)?\s*(?:万元|万|元)"#)
        var labeledRanges: [NSRange] = []
        for match in labeledPattern.matches(in: ocrText, range: fullRange) {
            guard let labelRange = Range(match.range(at: 1), in: ocrText),
                  let amountRange = Range(match.range(at: 3), in: ocrText) else { continue }
            let citation = normalizeAmountLabel(String(ocrText[labelRange])) + String(ocrText[amountRange])
            guard !facts.amounts.contains(citation) else { continue }
            facts.amounts.append(citation)
            labeledRanges.append(match.range)
            if facts.amounts.count >= 3 { break }
        }
        if facts.amounts.count < 3 {
            for match in plainPattern.matches(in: ocrText, range: fullRange) {
                if labeledRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                guard let r = Range(match.range, in: ocrText) else { continue }
                let amount = String(ocrText[r])
                guard !facts.amounts.contains(amount) else { continue }
                facts.amounts.append(amount)
                if facts.amounts.count >= 3 { break }
            }
        }

        return facts
    }

    /// Drop a leading 年月日 prefix from an amount label when it clearly belongs
    /// to the date ("月应发工资合计" → "应发工资合计"), while keeping real labels
    /// like "月薪" or "年终奖" intact.
    private func normalizeAmountLabel(_ label: String) -> String {
        var result = label
        while result.count > 3,
              let first = result.first, "年月日".contains(first),
              let second = result.dropFirst().first, "应实工合发放支金额薪资酬补欠".contains(second) {
            result.removeFirst()
        }
        return result
    }

    // MARK: - Draft composition

    private func buildProofContent(facts: ExtractedFacts, ocrText: String) -> String {
        var clauses: [String] = []
        if !facts.names.isEmpty {
            clauses.append("涉及\(facts.names.joined(separator: "、"))")
        }
        if !facts.dates.isEmpty {
            clauses.append("载明日期\(facts.dates.joined(separator: "、"))")
        }
        if !facts.amounts.isEmpty {
            clauses.append("载明\(facts.amounts.joined(separator: "、"))")
        }

        // No structured facts — fall back to a verbatim excerpt
        if clauses.isEmpty {
            if let type = facts.documentTypes.first {
                return "该证据为\(type)，内容为：\(ocrExcerpt(ocrText))"
            }
            return "该证据显示：\(ocrExcerpt(ocrText))"
        }

        var parts: [String] = []
        parts.append(facts.documentTypes.first.map { "该证据为\($0)" } ?? "该证据显示")
        parts.append(contentsOf: clauses)
        return parts.joined(separator: "，")
    }

    private func ocrExcerpt(_ ocrText: String) -> String {
        let lines = ocrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return String(lines.prefix(2).joined(separator: "；").prefix(200))
    }

    private func buildProofPurpose(
        ocrText: String,
        claims: [(number: Int, text: String)],
        facts: ExtractedFacts
    ) -> String {
        // 1. Claims are known and evidence keywords line up → attribute to claims
        var matched: [String] = []
        for rule in Self.purposeRules {
            guard rule.ocrKeywords.contains(where: { ocrText.contains($0) }) else { continue }
            let claimsHit = claims.contains { claim in
                rule.claimKeywords.contains { claim.text.contains($0) }
            }
            if claimsHit {
                matched.append(rule.purpose)
                if matched.count >= 2 { break }
            }
        }
        if !matched.isEmpty { return matched.joined(separator: "；") }

        // 2. No usable claim context → evidence-only purpose
        for rule in Self.purposeRules where rule.ocrKeywords.contains(where: { ocrText.contains($0) }) {
            return rule.ocrOnlyPurpose
        }

        // 3. Generic fallback
        if let type = facts.documentTypes.first {
            return "证明\(type)所载事实，作为支持相应仲裁请求的佐证"
        }
        return "证明该证据所载事实，作为支持相应仲裁请求的佐证"
    }

    // MARK: - Deterministic rules and keywords

    private struct PurposeRule {
        let ocrKeywords: [String]
        let claimKeywords: [String]
        let purpose: String
        let ocrOnlyPurpose: String
    }

    private static let purposeRules: [PurposeRule] = [
        PurposeRule(
            ocrKeywords: ["工资", "劳动报酬", "欠薪", "工资表", "工资条", "工资单",
                          "银行流水", "转账记录", "工资发放", "工资支付", "应发工资", "实发工资"],
            claimKeywords: ["工资", "劳动报酬", "欠薪"],
            purpose: "证明劳动报酬标准及工资实际发放情况，支持劳动报酬、欠薪相关仲裁请求",
            ocrOnlyPurpose: "证明劳动报酬标准及工资实际发放情况"),
        PurposeRule(
            ocrKeywords: ["解除", "离职", "辞退", "被迫"],
            claimKeywords: ["解除", "离职", "辞退", "被迫"],
            purpose: "证明劳动关系解除的事实及原因，支持解除劳动合同相关仲裁请求",
            ocrOnlyPurpose: "证明劳动关系解除的事实及原因"),
        PurposeRule(
            ocrKeywords: ["经济补偿", "赔偿金", "补偿金"],
            claimKeywords: ["经济补偿", "赔偿金", "补偿"],
            purpose: "证明经济补偿/赔偿金的计算依据，支持经济补偿相关仲裁请求",
            ocrOnlyPurpose: "证明经济补偿/赔偿金的计算依据"),
        PurposeRule(
            ocrKeywords: ["加班"],
            claimKeywords: ["加班"],
            purpose: "证明加班事实及加班时长，支持加班费相关仲裁请求",
            ocrOnlyPurpose: "证明加班事实及加班时长"),
        PurposeRule(
            ocrKeywords: ["未签订", "未签", "二倍工资", "双倍工资"],
            claimKeywords: ["未签订", "未签", "二倍工资", "双倍工资"],
            purpose: "证明未签订书面劳动合同的事实，支持未签合同二倍工资差额相关仲裁请求",
            ocrOnlyPurpose: "证明未签订书面劳动合同的事实"),
        PurposeRule(
            ocrKeywords: ["社保", "社会保险", "养老保险", "医疗保险", "失业保险", "公积金"],
            claimKeywords: ["社保", "社会保险", "公积金", "养老保险", "医疗保险"],
            purpose: "证明社会保险缴纳情况，支持社会保险补缴相关仲裁请求",
            ocrOnlyPurpose: "证明社会保险缴纳情况"),
        PurposeRule(
            ocrKeywords: ["年休假", "年假", "带薪年假", "带薪休假"],
            claimKeywords: ["年休假", "年假", "带薪"],
            purpose: "证明年休假安排及未休情况，支持未休年休假工资相关仲裁请求",
            ocrOnlyPurpose: "证明年休假安排及未休情况"),
        PurposeRule(
            ocrKeywords: ["劳动关系", "入职", "用工", "劳动合同", "录用通知书", "入职登记表"],
            claimKeywords: ["劳动关系", "入职", "用工"],
            purpose: "证明双方存在劳动关系，支持劳动关系确认相关仲裁请求",
            ocrOnlyPurpose: "证明双方存在劳动关系"),
    ]

    private static let documentTypeKeywords: [String] = [
        "解除劳动合同通知书", "解除劳动合同证明书", "劳动合同解除证明",
        "社会保险缴费记录", "社保缴费记录", "参保缴费凭证",
        "个人所得税纳税记录", "个人所得税完税证明",
        "银行转账记录", "银行流水", "银行对账单", "交易明细", "账户明细",
        "工资发放记录", "工资支付记录", "工资支付明细",
        "工资汇总表", "工资表", "工资条", "工资单",
        "电子打卡记录", "考勤记录", "考勤表", "打卡记录", "打卡明细",
        "加班记录", "加班审批表", "请假记录", "年休假记录",
        "仲裁裁决书", "仲裁调解书", "裁决书", "调解书",
        "微信聊天记录", "聊天记录", "短信记录", "电子邮件",
        "入职登记表", "录用通知书", "录用通知",
        "离职证明", "解除通知书",
        "劳动合同书", "劳动合同", "劳动协议",
        "参保证明",
        "营业执照", "工商登记信息",
        "工资卡", "工资账户",
        "承诺书", "欠条", "借条",
    ]

    // MARK: - Apply draft to model

    private func applyDraft(_ draft: CatalogDraft, to item: EvidenceItem) {
        _ = item.proofContentState.merge(
            newMachineValue: draft.proofContent,
            directlyAffected: true,
            evidenceVersion: 0
        )
        _ = item.proofPurposeState.merge(
            newMachineValue: draft.proofPurpose,
            directlyAffected: true,
            evidenceVersion: 0
        )
    }

    // MARK: - Deterministic checks

    private func checkStandardGaps(_ caseFile: CaseFile) -> [GapItem] {
        var gaps: [GapItem] = []
        let names = Set(caseFile.evidenceItems.map { $0.name })
        let checks: [(String, String, String)] = [
            ("劳动合同", "证明劳动关系和工资标准", "全部请求"),
            ("银行流水", "证明实际工资发放", "欠薪相关请求"),
            ("参保证明", "证明劳动关系存续期间", "全部请求"),
            ("工资表", "证明工资构成和标准", "欠薪相关请求"),
        ]
        for (type, purpose, claim) in checks {
            if !names.contains(where: { $0.contains(type) }) {
                gaps.append(GapItem(severity: .high,
                    description: "缺少\(type)", suggestedRemedy: purpose, relatedClaim: claim))
            }
        }
        return gaps
    }

    private func extractNumbers(from text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\d+\.?\d*"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Catalog Draft

struct CatalogDraft: Sendable {
    let proofContent: String
    let proofPurpose: String
}

// MARK: - Gap Detection Procedure

enum GapDetectionProcedure {
    static func build(for caseFile: CaseFile) throws -> Procedure {
        try Procedure(
            name: "gap_detection",
            steps: [
                Step(name: "check_required", kind: .judgment,
                     statutes: ["劳动关系确认", "拖欠工资"],
                     transitions: ["not_refuted": "check_mixed", "refuted": "collect"]),
                Step(name: "check_mixed", kind: .judgment,
                     statutes: ["关联企业混同用工"],
                     transitions: ["not_refuted": "check_salary", "refuted": "collect"]),
                Step(name: "check_salary", kind: .judgment,
                     statutes: ["工资标准核实"],
                     transitions: ["not_refuted": "collect", "refuted": "collect"]),
                Step(name: "collect", kind: .code, transitions: [:]),
            ],
            maxRounds: 5
        )
    }
}

enum GapDetectionStatutes {
    static let all = StatuteBook(statutes: [
        LaborLawStatutes.employmentRelationship,
        LaborLawStatutes.wageArrears,
        LaborLawStatutes.mixedEmployment,
        LaborLawStatutes.salaryStandard,
    ])
}
