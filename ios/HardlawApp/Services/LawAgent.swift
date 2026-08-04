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

    private func callLLM(prompt: String, fallback: CatalogDraft) async -> CatalogDraft {
        // Use deterministic extraction as fallback since no real LLM is configured
        let numbers = extractNumbers(from: prompt)
        let ocrSection = prompt.components(separatedBy: "## 原始证据文字").last ?? ""

        return CatalogDraft(
            proofContent: "该证据显示：\(ocrSection.prefix(200))",
            proofPurpose: "证明相关事实"
        )
    }

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
