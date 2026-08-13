import Foundation
import HardlawKit

// MARK: - Outcome types

public enum AutoFillOutcomeStatus: Sendable {
    case filled
    case rejectedUnverifiable
    case noSource
    case humanOverridden
    case skipped
}

public struct AutoFillOutcome: Sendable {
    public let itemNumber: Int
    public let status: AutoFillOutcomeStatus
    public let message: String

    public init(itemNumber: Int, status: AutoFillOutcomeStatus, message: String) {
        self.itemNumber = itemNumber
        self.status = status
        self.message = message
    }
}

// MARK: - Pipeline

/// Orchestrates AI auto-fill by composing:
/// 1. DocumentClassifier (deterministic taxonomy)
/// 2. LLM (MLX → AutoFillRuleEngine via FailSafeLLM)
/// 3. AutoFillParser (3-tier JSON extraction)
/// 4. Grounding gate (number-in-source verification)
/// 5. FieldState.merge (the sanctioned AI write path)
public enum AutoFillPipeline {

    // MARK: - Evidence auto-fill

    /// Run auto-fill on items with empty `proofContentState.displayValue` and non-empty OCR text.
    ///
    /// - Parameters:
    ///   - items: The evidence items to fill (modified in-place via FieldState.merge).
    ///   - llm: The LLM backend (typically FailSafeLLM wrapping MLX + AutoFillRuleEngine).
    ///   - evidenceVersion: Current `caseFile.evidenceVersion` for staleness tracking.
    ///   - claims: The case's arbitration claims; passed into the prompt so
    ///     `proof_purpose` can tie each piece of evidence to a specific claim.
    ///   - progress: Optional callback `(done, total)` after each item.
    /// - Returns: One outcome per processed item.
    @MainActor
    public static func fillEvidence(
        _ items: [EvidenceItem],
        llm: any LLMBackend,
        evidenceVersion: Int,
        claims: [String] = [],
        progress: ((Int, Int) -> Void)? = nil
    ) async -> [AutoFillOutcome] {
        // Candidates are items with empty display value but have OCR text
        let candidates = items.enumerated().filter { idx, item in
            (item.proofContentState.displayValue ?? "").isEmpty && !item.sourceOCRText.isEmpty
        }

        guard !candidates.isEmpty else { return [] }

        var outcomes: [AutoFillOutcome] = []
        let total = candidates.count

        for (done, (idx, item)) in candidates.enumerated() {
            progress?(done + 1, total)

            let fileName = item.name
            let ocrText = item.sourceOCRText

            // Step 1: Get classification candidates from deterministic classifier
            let topCandidates = DocumentClassifier.classifyTopN(fileName: fileName, ocrText: ocrText, n: 5)
            let candidateNames = topCandidates.map { $0.rawValue }

            // Step 2: Build prompt and call LLM
            let prompt = AutoFillPrompt.documentPrompt(
                name: fileName,
                candidates: candidateNames,
                ocrText: ocrText,
                claims: claims
            )

            let raw: String
            do {
                raw = try await llm.judge(prompt)
            } catch {
                outcomes.append(AutoFillOutcome(
                    itemNumber: item.number,
                    status: .skipped,
                    message: "LLM 调用失败：\(error.localizedDescription)"
                ))
                continue
            }

            // Step 3: Parse response
            guard let result = AutoFillParser.parseDocument(raw) else {
                outcomes.append(AutoFillOutcome(
                    itemNumber: item.number,
                    status: .skipped,
                    message: "无法解析 AI 响应"
                ))
                continue
            }

            // Step 4: Grounding gate — every number in proof_content must appear in source
            let numbersInContent = extractNumberTokens(from: result.proofContent)
            let allNumbersGrounded = numbersInContent.allSatisfy { number in
                ocrText.contains(number)
            }
            // Also check numbers_cited
            let citedNumbersGrounded = result.numbersCited.allSatisfy { number in
                ocrText.contains(number)
            }

            guard allNumbersGrounded && citedNumbersGrounded else {
                outcomes.append(AutoFillOutcome(
                    itemNumber: item.number,
                    status: .rejectedUnverifiable,
                    message: "AI 生成的内容包含原文中不存在的数据，已拒绝"
                ))
                continue
            }

            // Step 5: Write through FieldState.merge
            let contentAction = item.proofContentState.merge(
                newMachineValue: result.proofContent,
                directlyAffected: true,
                evidenceVersion: evidenceVersion
            )
            let purposeAction = item.proofPurposeState.merge(
                newMachineValue: result.proofPurpose,
                directlyAffected: false,
                evidenceVersion: evidenceVersion
            )

            // Set group if empty
            if item.group.isEmpty, let classification = DocumentClassifier.classify(fileName: fileName, ocrText: ocrText) {
                item.group = classification.rawValue
            }

            // Determine outcome status
            switch contentAction {
            case .flagForReview:
                outcomes.append(AutoFillOutcome(
                    itemNumber: item.number,
                    status: .humanOverridden,
                    message: "你的修改已保留，AI 建议未覆盖"
                ))
            case .promptForReconfirmation:
                outcomes.append(AutoFillOutcome(
                    itemNumber: item.number,
                    status: .filled,
                    message: "AI 更新了建议（你之前的确认可能需要复核）"
                ))
            default:
                outcomes.append(AutoFillOutcome(
                    itemNumber: item.number,
                    status: .filled,
                    message: "已自动填写证明内容" + (result.classification.isEmpty ? "" : "（\(result.classification)）")
                ))
            }
            _ = purposeAction // purpose is secondary; content drives the outcome
        }

        return outcomes
    }

    // MARK: - Metadata extraction

    /// Extract case metadata from key documents.
    /// The caller should apply results with the "empty-only" write policy:
    ///   - caseName, applicant, respondent: only if currently empty
    ///   - claims: only if no existing claim shares the content
    @MainActor
    public static func extractMetadata(
        from items: [EvidenceItem],
        llm: any LLMBackend
    ) async -> AutoFillMetadataResult? {
        // Select key documents: 合同, 解除通知, 仲裁申请书
        let keyDocPatterns = ["仲裁申请", "申请书", "劳动合同", "劳动协议", "解除通知", "被迫解除", "起诉状", "申诉书"]
        let keyDocs = items.filter { item in
            let name = item.name
            let text = item.sourceOCRText.prefix(500)
            return keyDocPatterns.contains { name.localizedCaseInsensitiveContains($0) || text.localizedCaseInsensitiveContains($0) }
        }.prefix(3)

        guard !keyDocs.isEmpty else { return nil }

        let docs: [(name: String, text: String)] = Array(keyDocs).map { (name: $0.name, text: $0.sourceOCRText) }
        let prompt = AutoFillPrompt.metadataPrompt(documents: docs)

        let raw: String
        do {
            raw = try await llm.judge(prompt)
        } catch {
            return nil
        }

        return AutoFillParser.parseMetadata(raw)
    }

    // MARK: - Helpers

    /// Extract number-like tokens for grounding verification.
    /// Only checks tokens containing digits — names, dates, amounts.
    private static func extractNumberTokens(from text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"[\d,，]+\.?\d*(?:\s*[元万千万元块人天年月日号])?"#, options: [])
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = pattern.matches(in: text, options: [], range: nsRange)
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}
